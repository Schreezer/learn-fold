//! Cloudflare Think chat transport for Learnfold's hosted course provider.
//!
//! Think owns the durable transcript, compaction overlays, recovery fiber, and
//! session identity. This module deliberately owns only the typed mobile wire
//! boundary and delegates client tool execution back to the platform.

use futures::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::watch;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::http::header::AUTHORIZATION;
use tokio_tungstenite::tungstenite::protocol::Message as WsMessage;
use url::Url;
use uuid::Uuid;

const AGENT_ROUTE: &str = "agents/hosted-course-agent";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(20);
const FRAME_TIMEOUT: Duration = Duration::from_secs(180);
const MAX_TOOL_SCHEMA_BYTES: usize = 256 * 1024;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum HostedAgentError {
    #[error("Invalid hosted-agent configuration: {detail}")]
    InvalidConfiguration { detail: String },
    #[error("Hosted-agent connection failed: {detail}")]
    Connection { detail: String },
    #[error("Hosted-agent protocol failed: {detail}")]
    Protocol { detail: String },
    #[error("Hosted-agent request failed: {detail}")]
    Request { detail: String },
    #[error("The hosted-agent request was cancelled")]
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostedAgentToolDefinition {
    pub name: String,
    pub description: String,
    pub parameters_json: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostedAgentToolInvocation {
    pub session_id: String,
    pub tool_call_id: String,
    pub tool_name: String,
    pub arguments_json: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostedAgentToolResult {
    pub success: bool,
    /// JSON value when possible. Plain text is accepted and encoded as a JSON
    /// string before it crosses the Think protocol.
    pub output: String,
    pub error_message: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostedAgentMessage {
    pub id: String,
    pub role: String,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostedAgentTurnResult {
    pub session_id: String,
    pub response_text: String,
}

#[uniffi::export(callback_interface)]
pub trait HostedAgentToolHandler: Send + Sync {
    fn execute_hosted_tool(&self, invocation: HostedAgentToolInvocation) -> HostedAgentToolResult;
}

#[uniffi::export(callback_interface)]
pub trait HostedAgentEventListener: Send + Sync {
    fn on_response_delta(&self, delta: String);
    fn on_recovering_changed(&self, recovering: bool);
}

#[derive(uniffi::Object)]
pub struct HostedAgentClient {
    base_url: Url,
    access_token: String,
    active_cancellations: Arc<Mutex<HashMap<String, ActiveCancellation>>>,
}

struct ActiveCancellation {
    token: Uuid,
    sender: watch::Sender<bool>,
}

struct CancellationRegistration {
    session_id: String,
    token: Uuid,
    receiver: watch::Receiver<bool>,
    active_cancellations: Arc<Mutex<HashMap<String, ActiveCancellation>>>,
}

impl Drop for CancellationRegistration {
    fn drop(&mut self) {
        let mut active = self
            .active_cancellations
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if active.get(&self.session_id).map(|entry| entry.token) == Some(self.token) {
            active.remove(&self.session_id);
        }
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl HostedAgentClient {
    #[uniffi::constructor]
    pub fn new(base_url: String, access_token: String) -> Result<Self, HostedAgentError> {
        let base_url = validated_base_url(&base_url)?;
        let access_token = access_token.trim().to_string();
        if access_token.is_empty() {
            return Err(HostedAgentError::InvalidConfiguration {
                detail: "the client access token is empty".into(),
            });
        }
        Ok(Self {
            base_url,
            access_token,
            active_cancellations: Arc::new(Mutex::new(HashMap::new())),
        })
    }

    /// Cancels an in-flight turn for this client and session. The send loop
    /// emits Think's canonical cancel frame on its existing WebSocket before
    /// returning, so cancelling Swift's UniFFI task cannot strand a cloud turn.
    pub fn cancel(&self, session_id: String) -> Result<bool, HostedAgentError> {
        validate_session_id(&session_id)?;
        let active = self
            .active_cancellations
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        Ok(active
            .get(&session_id)
            .map(|entry| entry.sender.send(true).is_ok())
            .unwrap_or(false))
    }

    /// Reads the server-authoritative transcript. No local transcript is used
    /// as a fallback: a failure stays visible so callers never show stale
    /// history as if it were current.
    pub async fn load_messages(
        &self,
        session_id: String,
    ) -> Result<Vec<HostedAgentMessage>, HostedAgentError> {
        validate_session_id(&session_id)?;
        let (mut socket, messages) = self.connect(&session_id).await?;
        let _ = socket.close(None).await;
        Ok(project_messages(&messages))
    }

    /// Sends one user turn. Think remains authoritative for persistence,
    /// compaction, recovery and auto-continuation. Client tool calls are
    /// executed synchronously at the UniFFI boundary, then returned to Think
    /// with `autoContinue` so its agent loop resumes durably.
    pub async fn send(
        &self,
        session_id: String,
        workspace_id: String,
        prompt: String,
        tools: Vec<HostedAgentToolDefinition>,
        tool_handler: Box<dyn HostedAgentToolHandler>,
        listener: Box<dyn HostedAgentEventListener>,
    ) -> Result<HostedAgentTurnResult, HostedAgentError> {
        validate_session_id(&session_id)?;
        validate_workspace_id(&workspace_id)?;
        if prompt.trim().is_empty() {
            return Err(HostedAgentError::InvalidConfiguration {
                detail: "the prompt is empty".into(),
            });
        }

        let client_tools = tool_schemas(&tools)?;
        let mut cancellation = self.register_cancellation(&session_id);
        let (mut socket, mut messages) = self.connect(&session_id).await?;
        if *cancellation.receiver.borrow() {
            return Err(HostedAgentError::Cancelled);
        }
        messages.push(json!({
            "id": Uuid::new_v4().to_string(),
            "role": "user",
            "parts": [{ "type": "text", "text": prompt }],
        }));

        let request_id = Uuid::new_v4().to_string();
        let body = json!({
            "messages": messages,
            "clientTools": client_tools,
            "workspaceId": workspace_id,
        });
        send_json(
            &mut socket,
            &json!({
                "type": "cf_agent_use_chat_request",
                "id": request_id,
                "init": {
                    "method": "POST",
                    "body": serde_json::to_string(&body).map_err(protocol_error)?,
                },
            }),
        )
        .await?;

        let tool_handler: Arc<dyn HostedAgentToolHandler> = Arc::from(tool_handler);
        let listener: Arc<dyn HostedAgentEventListener> = Arc::from(listener);
        let mut response_text = String::new();
        let mut handled_tool_calls = HashSet::new();
        let mut tool_continuation_pending = false;
        let mut saw_tool_call = false;

        loop {
            let frame =
                next_json_or_cancel(&mut socket, &mut cancellation.receiver, &request_id).await?;
            match frame.get("type").and_then(Value::as_str) {
                Some("cf_agent_stream_resuming") => {
                    if let Some(id) = frame.get("id").and_then(Value::as_str) {
                        send_json(
                            &mut socket,
                            &json!({
                                "type": "cf_agent_stream_resume_ack",
                                "id": id,
                            }),
                        )
                        .await?;
                    }
                }
                Some("cf_agent_chat_recovering") => {
                    listener.on_recovering_changed(
                        frame
                            .get("recovering")
                            .and_then(Value::as_bool)
                            .unwrap_or(false),
                    );
                }
                Some("cf_agent_use_chat_response") => {
                    let continuation = frame
                        .get("continuation")
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    if continuation
                        && tool_continuation_pending
                        && frame.get("done").and_then(Value::as_bool) != Some(true)
                    {
                        tool_continuation_pending = false;
                    }
                    if frame.get("error").and_then(Value::as_bool) == Some(true) {
                        let detail = frame
                            .get("body")
                            .and_then(Value::as_str)
                            .filter(|value| !value.is_empty())
                            .unwrap_or("the hosted model returned an error");
                        return Err(HostedAgentError::Request {
                            detail: detail.to_string(),
                        });
                    }

                    if frame.get("done").and_then(Value::as_bool) == Some(true) {
                        if !tool_continuation_pending && (!saw_tool_call || continuation) {
                            break;
                        }
                        continue;
                    }

                    let Some(chunk) = frame
                        .get("body")
                        .and_then(Value::as_str)
                        .filter(|body| !body.is_empty())
                        .and_then(|body| serde_json::from_str::<Value>(body).ok())
                    else {
                        continue;
                    };

                    if chunk.get("type").and_then(Value::as_str) == Some("text-delta") {
                        if let Some(delta) = chunk.get("delta").and_then(Value::as_str) {
                            response_text.push_str(delta);
                            listener.on_response_delta(delta.to_string());
                        }
                    }

                    if let Some((tool_call_id, tool_name, input)) = tool_call(&chunk) {
                        if !handled_tool_calls.insert(tool_call_id.to_string()) {
                            continue;
                        }
                        saw_tool_call = true;
                        let result = tool_handler.execute_hosted_tool(HostedAgentToolInvocation {
                            session_id: session_id.clone(),
                            tool_call_id: tool_call_id.to_string(),
                            tool_name: tool_name.to_string(),
                            arguments_json: serde_json::to_string(input).map_err(protocol_error)?,
                        });
                        let output = serde_json::from_str::<Value>(&result.output)
                            .unwrap_or_else(|_| Value::String(result.output));
                        let state = if result.success {
                            "output-available"
                        } else {
                            "output-error"
                        };
                        send_json(
                            &mut socket,
                            &json!({
                                "type": "cf_agent_tool_result",
                                "toolCallId": tool_call_id,
                                "toolName": tool_name,
                                "output": output,
                                "state": state,
                                "errorText": result.error_message,
                                "autoContinue": true,
                                "clientTools": client_tools,
                            }),
                        )
                        .await?;
                        tool_continuation_pending = true;
                    }
                }
                _ => {}
            }
        }

        let _ = socket.close(None).await;
        Ok(HostedAgentTurnResult {
            session_id,
            response_text,
        })
    }
}

type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

impl HostedAgentClient {
    fn register_cancellation(&self, session_id: &str) -> CancellationRegistration {
        let token = Uuid::new_v4();
        let (sender, receiver) = watch::channel(false);
        let mut active = self
            .active_cancellations
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(previous) =
            active.insert(session_id.to_string(), ActiveCancellation { token, sender })
        {
            let _ = previous.sender.send(true);
        }
        CancellationRegistration {
            session_id: session_id.to_string(),
            token,
            receiver,
            active_cancellations: Arc::clone(&self.active_cancellations),
        }
    }

    async fn connect(&self, session_id: &str) -> Result<(Socket, Vec<Value>), HostedAgentError> {
        let url = websocket_url(&self.base_url, session_id)?;
        let mut request = url
            .as_str()
            .into_client_request()
            .map_err(connection_error)?;
        request.headers_mut().insert(
            AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {}", self.access_token)).map_err(|error| {
                HostedAgentError::InvalidConfiguration {
                    detail: format!("invalid access token: {error}"),
                }
            })?,
        );
        let (mut socket, _) = tokio::time::timeout(CONNECT_TIMEOUT, connect_async(request))
            .await
            .map_err(|_| HostedAgentError::Connection {
                detail: "connection timed out".into(),
            })?
            .map_err(connection_error)?;

        loop {
            let frame = next_json(&mut socket).await?;
            match frame.get("type").and_then(Value::as_str) {
                Some("cf_agent_chat_messages") => {
                    let messages = frame
                        .get("messages")
                        .and_then(Value::as_array)
                        .cloned()
                        .unwrap_or_default();
                    return Ok((socket, messages));
                }
                Some("cf_agent_stream_resuming") => {
                    if let Some(id) = frame.get("id").and_then(Value::as_str) {
                        send_json(
                            &mut socket,
                            &json!({
                                "type": "cf_agent_stream_resume_ack",
                                "id": id,
                            }),
                        )
                        .await?;
                    }
                }
                _ => {}
            }
        }
    }
}

fn validated_base_url(raw: &str) -> Result<Url, HostedAgentError> {
    let url = Url::parse(raw.trim()).map_err(|error| HostedAgentError::InvalidConfiguration {
        detail: format!("invalid base URL: {error}"),
    })?;
    if !matches!(url.scheme(), "https" | "http" | "wss" | "ws") || url.host_str().is_none() {
        return Err(HostedAgentError::InvalidConfiguration {
            detail: "base URL must be an absolute HTTP(S) or WebSocket URL".into(),
        });
    }
    Ok(url)
}

fn validate_session_id(value: &str) -> Result<(), HostedAgentError> {
    Uuid::parse_str(value).map_err(|_| HostedAgentError::InvalidConfiguration {
        detail: "session ID must be a UUID".into(),
    })?;
    Ok(())
}

fn validate_workspace_id(value: &str) -> Result<(), HostedAgentError> {
    let valid = !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'));
    if !valid {
        return Err(HostedAgentError::InvalidConfiguration {
            detail: "workspace ID contains unsupported characters".into(),
        });
    }
    Ok(())
}

fn websocket_url(base_url: &Url, session_id: &str) -> Result<Url, HostedAgentError> {
    let mut url = base_url.clone();
    let scheme = match base_url.scheme() {
        "https" => "wss",
        "http" => "ws",
        "wss" => "wss",
        "ws" => "ws",
        _ => unreachable!("validated_base_url restricts schemes"),
    };
    url.set_scheme(scheme)
        .map_err(|_| HostedAgentError::InvalidConfiguration {
            detail: "could not convert base URL to WebSocket URL".into(),
        })?;
    let prefix = base_url.path().trim_matches('/');
    let path = if prefix.is_empty() {
        format!("/{AGENT_ROUTE}/{session_id}")
    } else {
        format!("/{prefix}/{AGENT_ROUTE}/{session_id}")
    };
    url.set_path(&path);
    url.set_query(None);
    url.set_fragment(None);
    Ok(url)
}

fn tool_schemas(definitions: &[HostedAgentToolDefinition]) -> Result<Value, HostedAgentError> {
    let mut total_bytes = 0usize;
    let mut names = HashSet::new();
    let mut schemas = Vec::with_capacity(definitions.len());
    for definition in definitions {
        if definition.name.is_empty() || !names.insert(definition.name.as_str()) {
            return Err(HostedAgentError::InvalidConfiguration {
                detail: format!("invalid or duplicate tool name: {}", definition.name),
            });
        }
        total_bytes = total_bytes.saturating_add(definition.parameters_json.len());
        if total_bytes > MAX_TOOL_SCHEMA_BYTES {
            return Err(HostedAgentError::InvalidConfiguration {
                detail: "client tool schemas exceed the size limit".into(),
            });
        }
        let parameters =
            serde_json::from_str::<Value>(&definition.parameters_json).map_err(|error| {
                HostedAgentError::InvalidConfiguration {
                    detail: format!("invalid schema for {}: {error}", definition.name),
                }
            })?;
        schemas.push(json!({
            "name": definition.name,
            "description": definition.description,
            "parameters": parameters,
        }));
    }
    Ok(Value::Array(schemas))
}

fn tool_call(chunk: &Value) -> Option<(&str, &str, &Value)> {
    if !matches!(
        chunk.get("type").and_then(Value::as_str),
        Some("tool-input-available" | "tool-call")
    ) {
        return None;
    }
    Some((
        chunk.get("toolCallId")?.as_str()?,
        chunk.get("toolName")?.as_str()?,
        chunk.get("input").unwrap_or(&Value::Null),
    ))
}

fn project_messages(messages: &[Value]) -> Vec<HostedAgentMessage> {
    messages
        .iter()
        .filter_map(|message| {
            let id = message.get("id")?.as_str()?.to_string();
            let role = message.get("role")?.as_str()?.to_string();
            let text = message
                .get("parts")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter(|part| part.get("type").and_then(Value::as_str) == Some("text"))
                .filter_map(|part| part.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("");
            (!text.is_empty()).then_some(HostedAgentMessage { id, role, text })
        })
        .collect()
}

async fn send_json(socket: &mut Socket, value: &Value) -> Result<(), HostedAgentError> {
    socket
        .send(WsMessage::Text(value.to_string().into()))
        .await
        .map_err(connection_error)
}

async fn next_json(socket: &mut Socket) -> Result<Value, HostedAgentError> {
    tokio::time::timeout(FRAME_TIMEOUT, next_json_without_timeout(socket))
        .await
        .map_err(|_| HostedAgentError::Connection {
            detail: "the hosted agent stopped responding".into(),
        })?
}

async fn next_json_without_timeout(socket: &mut Socket) -> Result<Value, HostedAgentError> {
    loop {
        let frame = socket
            .next()
            .await
            .ok_or_else(|| HostedAgentError::Connection {
                detail: "the hosted agent closed the connection".into(),
            })?
            .map_err(connection_error)?;
        match frame {
            WsMessage::Text(text) => return serde_json::from_str(&text).map_err(protocol_error),
            WsMessage::Binary(bytes) => {
                return serde_json::from_slice(&bytes).map_err(protocol_error);
            }
            WsMessage::Ping(payload) => {
                socket
                    .send(WsMessage::Pong(payload))
                    .await
                    .map_err(connection_error)?;
            }
            WsMessage::Close(frame) => {
                return Err(HostedAgentError::Connection {
                    detail: frame
                        .map(|frame| frame.reason.to_string())
                        .filter(|reason| !reason.is_empty())
                        .unwrap_or_else(|| "the hosted agent closed the connection".into()),
                });
            }
            _ => {}
        }
    }
}

async fn next_json_or_cancel(
    socket: &mut Socket,
    cancellation: &mut watch::Receiver<bool>,
    request_id: &str,
) -> Result<Value, HostedAgentError> {
    tokio::select! {
        result = next_json(socket) => result,
        changed = cancellation.changed() => {
            if changed.is_ok() && *cancellation.borrow() {
                let _ = send_json(socket, &json!({
                    "type": "cf_agent_chat_request_cancel",
                    "id": request_id,
                })).await;
            }
            Err(HostedAgentError::Cancelled)
        }
    }
}

fn connection_error(error: impl std::fmt::Display) -> HostedAgentError {
    HostedAgentError::Connection {
        detail: error.to_string(),
    }
}

fn protocol_error(error: impl std::fmt::Display) -> HostedAgentError {
    HostedAgentError::Protocol {
        detail: error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_canonical_think_websocket_route() {
        let base = validated_base_url("https://agent.learnfold.example/runtime").unwrap();
        let session = "123e4567-e89b-12d3-a456-426614174000";
        assert_eq!(
            websocket_url(&base, session).unwrap().as_str(),
            "wss://agent.learnfold.example/runtime/agents/hosted-course-agent/123e4567-e89b-12d3-a456-426614174000"
        );
    }

    #[test]
    fn serializes_client_tool_schemas_and_rejects_duplicates() {
        let definition = HostedAgentToolDefinition {
            name: "native-editor-fetch".into(),
            description: "Fetch a page".into(),
            parameters_json: r#"{"type":"object"}"#.into(),
        };
        let schemas = tool_schemas(std::slice::from_ref(&definition)).unwrap();
        assert_eq!(schemas[0]["parameters"]["type"], "object");
        assert!(tool_schemas(&[definition.clone(), definition]).is_err());
    }

    #[test]
    fn projects_text_without_treating_tool_output_as_chat_text() {
        let messages = vec![json!({
            "id": "assistant-1",
            "role": "assistant",
            "parts": [
                { "type": "text", "text": "Ready" },
                { "type": "tool-native-editor-fetch", "output": { "secret": true } }
            ]
        })];
        assert_eq!(
            project_messages(&messages),
            vec![HostedAgentMessage {
                id: "assistant-1".into(),
                role: "assistant".into(),
                text: "Ready".into(),
            }]
        );
    }

    #[test]
    fn parses_available_client_tool_calls() {
        let chunk = json!({
            "type": "tool-input-available",
            "toolCallId": "call-1",
            "toolName": "present_course_plan",
            "input": { "plan_id": "rust" }
        });
        let (id, name, input) = tool_call(&chunk).unwrap();
        assert_eq!(id, "call-1");
        assert_eq!(name, "present_course_plan");
        assert_eq!(input["plan_id"], "rust");
    }

    #[test]
    fn cancellation_is_scoped_to_the_active_session() {
        let client = HostedAgentClient::new(
            "https://agent.learnfold.example".into(),
            "test-access-token".into(),
        )
        .unwrap();
        let session = "123e4567-e89b-12d3-a456-426614174000";
        let registration = client.register_cancellation(session);

        assert!(!*registration.receiver.borrow());
        assert!(client.cancel(session.into()).unwrap());
        assert!(*registration.receiver.borrow());

        drop(registration);
        assert!(!client.cancel(session.into()).unwrap());
    }
}
