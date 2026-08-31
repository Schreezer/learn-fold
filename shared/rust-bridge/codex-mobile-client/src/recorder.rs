use std::sync::Mutex;
use std::time::Instant;

use codex_app_server_protocol::{ClientRequest, ServerNotification};
use serde::{Deserialize, Serialize};
use serde_json::json;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordedEntry {
    pub ts_ms: u64,
    pub dir: Direction,
    pub server_id: String,
    pub json: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Direction {
    #[serde(rename = "in")]
    In,
    #[serde(rename = "out")]
    Out,
}

pub struct MessageRecorder {
    state: Mutex<RecorderState>,
}

struct RecorderState {
    is_recording: bool,
    start: Option<Instant>,
    entries: Vec<RecordedEntry>,
}

impl MessageRecorder {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(RecorderState {
                is_recording: false,
                start: None,
                entries: Vec::new(),
            }),
        }
    }

    pub fn start_recording(&self) {
        let mut s = self.state.lock().unwrap();
        s.entries.clear();
        s.start = Some(Instant::now());
        s.is_recording = true;
    }

    pub fn is_recording(&self) -> bool {
        self.state.lock().unwrap().is_recording
    }

    pub fn record_notification(&self, server_id: &str, notification: &ServerNotification) {
        let mut s = self.state.lock().unwrap();
        if !s.is_recording {
            return;
        }
        let ts_ms = s.start.map(|t| t.elapsed().as_millis() as u64).unwrap_or(0);
        if let Ok(json) = serde_json::to_string(notification) {
            s.entries.push(RecordedEntry {
                ts_ms,
                dir: Direction::In,
                server_id: server_id.to_string(),
                json,
            });
        }
    }

    pub fn record_request(&self, server_id: &str, request: &ClientRequest) {
        let mut s = self.state.lock().unwrap();
        if !s.is_recording {
            return;
        }
        let ts_ms = s.start.map(|t| t.elapsed().as_millis() as u64).unwrap_or(0);
        if let Ok(json) = recorded_request_json(request) {
            s.entries.push(RecordedEntry {
                ts_ms,
                dir: Direction::Out,
                server_id: server_id.to_string(),
                json,
            });
        }
    }

    pub fn stop_recording(&self) -> String {
        let mut s = self.state.lock().unwrap();
        s.is_recording = false;
        s.start = None;
        let entries = std::mem::take(&mut s.entries);
        serde_json::to_string(&entries).unwrap_or_else(|_| "[]".to_string())
    }

    /// Parse a recording and return entries for replay.
    pub fn parse_recording(data: &str) -> Result<Vec<RecordedEntry>, String> {
        serde_json::from_str(data).map_err(|e| format!("parse recording: {e}"))
    }

    /// Replay inbound notifications from a recording, rewriting server/thread
    /// IDs so the updates land on the caller's active thread.
    pub fn replay_entries(
        data: &str,
        target_server_id: &str,
        target_thread_id: &str,
    ) -> Result<Vec<(u64, String, ServerNotification)>, String> {
        let entries: Vec<RecordedEntry> =
            serde_json::from_str(data).map_err(|e| format!("parse recording: {e}"))?;

        // Discover the original server_id and thread_id from the first inbound entry.
        let source_server_id = entries
            .iter()
            .find(|e| e.dir == Direction::In)
            .map(|e| e.server_id.clone());
        let source_thread_id = entries.iter().find_map(|e| {
            if e.dir != Direction::In {
                return None;
            }
            // Extract thread_id from the notification JSON params.
            let v: serde_json::Value = serde_json::from_str(&e.json).ok()?;
            v.get("params")
                .and_then(|p| p.get("threadId").or_else(|| p.get("thread_id")))
                .and_then(|t| t.as_str())
                .or_else(|| {
                    v.get("params")
                        .and_then(|p| p.get("thread"))
                        .and_then(|t| t.get("id"))
                        .and_then(|id| id.as_str())
                })
                .map(|s| s.to_string())
        });

        let mut result = Vec::new();
        for entry in entries {
            if entry.dir != Direction::In {
                continue;
            }
            // Rewrite IDs in the raw JSON before deserializing.
            let mut json = entry.json.clone();
            if let Some(ref src_tid) = source_thread_id {
                json = json.replace(src_tid, target_thread_id);
            }
            if let Some(ref src_sid) = source_server_id {
                // Only rewrite in the JSON payload, not the entry server_id.
                json = json.replace(src_sid, target_server_id);
            }
            match serde_json::from_str::<ServerNotification>(&json) {
                Ok(notification) => {
                    result.push((entry.ts_ms, target_server_id.to_string(), notification));
                }
                Err(e) => {
                    tracing::warn!("skip undeserializable recording entry: {e}");
                }
            }
        }
        Ok(result)
    }
}

fn recorded_request_json(request: &ClientRequest) -> serde_json::Result<String> {
    match request {
        ClientRequest::LoginAccount { request_id, .. } => serde_json::to_string(&json!({
            "method": "account/login/start",
            "id": request_id,
            "params": {
                "redacted": true
            }
        })),
        _ => serde_json::to_string(request),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use codex_app_server_protocol::{
        LoginAccountParams, RequestId, ThreadArchivedNotification, ThreadClosedNotification,
    };

    const API_KEY_CANARY: &str = "sk-recorder-api-key-canary-never-persist";
    const CHATGPT_TOKEN_CANARY: &str = "eyJ-recorder-chatgpt-token-canary-never-persist";

    fn record_single_request(request: &ClientRequest) -> (String, RecordedEntry) {
        let recorder = MessageRecorder::new();
        recorder.start_recording();
        recorder.record_request("local-test", request);
        let recording = recorder.stop_recording();
        let mut entries = MessageRecorder::parse_recording(&recording)
            .expect("recorded request should produce valid recording JSON");
        assert_eq!(entries.len(), 1);
        (recording, entries.remove(0))
    }

    fn assert_credential_absent(recording: &str, credential: &str) {
        assert!(
            !recording
                .as_bytes()
                .windows(credential.len())
                .any(|window| window == credential.as_bytes()),
            "recording contained credential bytes"
        );
    }

    fn assert_redacted_login_entry(entry: &RecordedEntry, expected_id: i64) {
        assert_eq!(entry.dir, Direction::Out);
        let json: serde_json::Value =
            serde_json::from_str(&entry.json).expect("entry should contain valid request JSON");
        assert_eq!(
            json,
            json!({
                "method": "account/login/start",
                "id": expected_id,
                "params": {
                    "redacted": true
                }
            })
        );
    }

    #[test]
    fn api_key_login_recording_redacts_credentials() {
        let request = ClientRequest::LoginAccount {
            request_id: RequestId::Integer(41),
            params: LoginAccountParams::ApiKey {
                api_key: API_KEY_CANARY.to_string(),
            },
        };

        let (recording, entry) = record_single_request(&request);

        assert_credential_absent(&recording, API_KEY_CANARY);
        assert_redacted_login_entry(&entry, 41);
    }

    #[test]
    fn chatgpt_token_login_recording_redacts_credentials() {
        let request = ClientRequest::LoginAccount {
            request_id: RequestId::Integer(42),
            params: LoginAccountParams::ChatgptAuthTokens {
                access_token: CHATGPT_TOKEN_CANARY.to_string(),
                chatgpt_account_id: "synthetic-account".to_string(),
                chatgpt_plan_type: Some("synthetic-plan".to_string()),
            },
        };

        let (recording, entry) = record_single_request(&request);

        assert_credential_absent(&recording, CHATGPT_TOKEN_CANARY);
        assert_redacted_login_entry(&entry, 42);
    }

    #[test]
    fn non_sensitive_request_recording_is_unchanged() {
        let request: ClientRequest = serde_json::from_value(json!({
            "method": "model/list",
            "id": 43,
            "params": {
                "limit": 5
            }
        }))
        .expect("model/list should be a valid request");
        let expected = serde_json::to_value(&request).expect("request should serialize");

        let (_, entry) = record_single_request(&request);
        let actual: serde_json::Value =
            serde_json::from_str(&entry.json).expect("entry should contain valid request JSON");

        assert_eq!(actual, expected);
    }

    #[test]
    fn replay_ignores_redacted_login_between_ordered_inbound_notifications() {
        let source_thread_id = "synthetic-source-thread";
        let target_thread_id = "synthetic-target-thread";
        let login = ClientRequest::LoginAccount {
            request_id: RequestId::Integer(44),
            params: LoginAccountParams::ApiKey {
                api_key: API_KEY_CANARY.to_string(),
            },
        };
        let first = ServerNotification::ThreadArchived(ThreadArchivedNotification {
            thread_id: source_thread_id.to_string(),
        });
        let second = ServerNotification::ThreadClosed(ThreadClosedNotification {
            thread_id: source_thread_id.to_string(),
        });
        let entries = vec![
            RecordedEntry {
                ts_ms: 10,
                dir: Direction::In,
                server_id: "synthetic-source-server".to_string(),
                json: serde_json::to_string(&first).expect("first notification should serialize"),
            },
            RecordedEntry {
                ts_ms: 20,
                dir: Direction::Out,
                server_id: "synthetic-source-server".to_string(),
                json: recorded_request_json(&login).expect("login marker should serialize"),
            },
            RecordedEntry {
                ts_ms: 30,
                dir: Direction::In,
                server_id: "synthetic-source-server".to_string(),
                json: serde_json::to_string(&second).expect("second notification should serialize"),
            },
        ];
        let recording = serde_json::to_string(&entries).expect("recording should serialize");

        assert_credential_absent(&recording, API_KEY_CANARY);
        let replayed = MessageRecorder::replay_entries(
            &recording,
            "synthetic-target-server",
            target_thread_id,
        )
        .expect("mixed recording should replay");

        assert_eq!(replayed.len(), 2, "outbound entries must remain ignored");

        let (first_ts, first_server, first_notification) = &replayed[0];
        assert_eq!(*first_ts, 10);
        assert_eq!(first_server, "synthetic-target-server");
        match first_notification {
            ServerNotification::ThreadArchived(notification) => {
                assert_eq!(notification.thread_id, target_thread_id);
            }
            other => {
                panic!("expected first replayed notification to be ThreadArchived, got {other:?}")
            }
        }

        let (second_ts, second_server, second_notification) = &replayed[1];
        assert_eq!(*second_ts, 30);
        assert_eq!(second_server, "synthetic-target-server");
        match second_notification {
            ServerNotification::ThreadClosed(notification) => {
                assert_eq!(notification.thread_id, target_thread_id);
            }
            other => {
                panic!("expected second replayed notification to be ThreadClosed, got {other:?}")
            }
        }
    }
}
