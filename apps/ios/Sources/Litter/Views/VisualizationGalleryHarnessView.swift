#if DEBUG
import NativeBlockEditorUI
import SwiftUI

/// A fixed set of typical and deliberately broken visualizations, rendered by
/// the production HTML block next to what the save-time check tells the agent.
/// Screenshot it in light, dark, and the largest text size to review changes.
struct VisualizationGalleryHarnessView: View {
    static let argument = "--ui-test-visualization-gallery"
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }

    /// `LEARNFOLD_GALLERY_SAMPLE=<id>` shows a single sample, for screenshots.
    private var samples: [VisualizationGallerySample] {
        let only = ProcessInfo.processInfo.environment["LEARNFOLD_GALLERY_SAMPLE"]
        return VisualizationGallerySample.all.filter { only == nil || $0.id == only }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    ForEach(samples) { sample in
                        VisualizationGalleryRow(sample: sample)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("Visualizations")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct VisualizationGalleryRow: View {
    let sample: VisualizationGallerySample
    @State private var inspection: HTMLBlockInspection?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sample.title).font(.headline)
                Text(sample.expectation).font(.footnote).foregroundStyle(.secondary)
            }
            BrowserHTMLBlockContainer(
                html: sample.html,
                allowNetwork: false,
                allowJavaScript: true,
                identifier: "gallery-\(sample.id)"
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            checkSummary
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gallery-sample-\(sample.id)")
        .task { inspection = await HTMLBlockInspector.inspect(html: sample.html) }
    }

    @ViewBuilder
    private var checkSummary: some View {
        if let inspection {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    inspection.passed ? "Check passed" : "Agent is told to fix \(inspection.issues.count)",
                    systemImage: inspection.passed ? "checkmark.seal.fill" : "wrench.and.screwdriver.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(inspection.passed ? .green : .orange)
                ForEach(inspection.issues, id: \.self) { issue in
                    Text("• \(issue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("gallery-check-\(sample.id)")
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

struct VisualizationGallerySample: Identifiable {
    let id: String
    let title: String
    let expectation: String
    let html: String

    static let all: [VisualizationGallerySample] = [
        .init(
            id: "slider",
            title: "Slider with live result",
            expectation: "Passes. Drag to change the rate.",
            html: """
            <style>
            .cmp { display: grid; gap: 10px; }
            .cmp label { display: flex; justify-content: space-between; font-weight: 600; }
            .cmp input { width: 100%; accent-color: #007aff; }
            .cmp output { font-size: 28px; font-weight: 700; font-variant-numeric: tabular-nums; }
            </style>
            <div class="cmp">
              <label for="rate">Annual rate <span id="rate-value">5%</span></label>
              <input id="rate" type="range" min="0" max="15" value="5">
              <output id="total" aria-live="polite">$1,629 after 10 years</output>
            </div>
            <script>
            (function() {
              var rate = document.getElementById('rate');
              var update = function() {
                var r = Number(rate.value);
                document.getElementById('rate-value').textContent = r + '%';
                var total = 1000 * Math.pow(1 + r / 100, 10);
                document.getElementById('total').textContent = '$' + Math.round(total).toLocaleString() + ' after 10 years';
              };
              rate.addEventListener('input', update);
              update();
            })();
            </script>
            """
        ),
        .init(
            id: "chart",
            title: "SVG chart that switches series",
            expectation: "Passes. Tap a year to redraw.",
            html: """
            <style>
            .bars { display: grid; gap: 8px; }
            .bars svg { width: 100%; height: auto; }
            .bars rect { fill: #34c759; transition: height .3s, y .3s; }
            .bars .years { display: flex; gap: 6px; }
            .bars button { flex: 1; min-height: 40px; border-radius: 8px; border: 1px solid color-mix(in srgb, currentColor 25%, transparent); background: transparent; color: inherit; font: inherit; }
            .bars button[aria-pressed=true] { background: #34c759; color: white; border-color: #34c759; }
            </style>
            <div class="bars">
              <svg viewBox="0 0 300 140" role="img" aria-label="Quarterly revenue"><g id="g"></g></svg>
              <div class="years" role="group" aria-label="Year">
                <button type="button" data-y="0" aria-pressed="true">2024</button>
                <button type="button" data-y="1" aria-pressed="false">2025</button>
              </div>
              <p id="caption" aria-live="polite">2024: revenue peaks in Q4.</p>
            </div>
            <script>
            (function() {
              var data = [[40, 70, 55, 120], [60, 65, 90, 100]];
              var captions = ['2024: revenue peaks in Q4.', '2025: growth is steadier across the year.'];
              var draw = function(y) {
                var g = document.getElementById('g');
                g.innerHTML = '';
                data[y].forEach(function(v, i) {
                  var r = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
                  r.setAttribute('x', 20 + i * 70); r.setAttribute('width', 50);
                  r.setAttribute('y', 130 - v); r.setAttribute('height', v); r.setAttribute('rx', 4);
                  g.appendChild(r);
                });
                document.getElementById('caption').textContent = captions[y];
                document.querySelectorAll('.years button').forEach(function(b) {
                  b.setAttribute('aria-pressed', String(Number(b.dataset.y) === y));
                });
              };
              document.querySelectorAll('.years button').forEach(function(b) {
                b.addEventListener('click', function() { draw(Number(b.dataset.y)); });
              });
              draw(0);
            })();
            </script>
            """
        ),
        .init(
            id: "stepper",
            title: "Step-through process",
            expectation: "Passes. Next walks through the steps.",
            html: """
            <style>
            .steps ol { padding-left: 20px; margin: 0 0 10px; }
            .steps li { opacity: .35; padding: 4px 0; }
            .steps li.on { opacity: 1; font-weight: 600; }
            .steps button { min-height: 44px; padding: 0 16px; border: 0; border-radius: 10px; background: #007aff; color: white; font: inherit; font-weight: 600; }
            </style>
            <div class="steps">
              <ol id="list"><li>Borrower applies</li><li>Bank checks credit</li><li>Loan is approved</li><li>Money is created as a deposit</li></ol>
              <button id="next" type="button">Next step</button>
              <p id="where" aria-live="polite">Step 1 of 4</p>
            </div>
            <script>
            (function() {
              var step = 0, items = document.querySelectorAll('#list li');
              var show = function() {
                items.forEach(function(li, i) { li.classList.toggle('on', i <= step); });
                document.getElementById('where').textContent = 'Step ' + (step + 1) + ' of ' + items.length;
              };
              document.getElementById('next').addEventListener('click', function() { step = (step + 1) % items.length; show(); });
              show();
            })();
            </script>
            """
        ),
        .init(
            id: "canvas",
            title: "Canvas wave",
            expectation: "Passes. Frequency redraws the wave.",
            html: """
            <style>canvas { width: 100%; height: 120px; display: block; } label { display: block; margin-top: 8px; }</style>
            <canvas id="wave" width="600" height="240" role="img" aria-label="Sine wave"></canvas>
            <label>Frequency <input id="freq" type="range" min="1" max="6" value="2"></label>
            <output id="freq-out" aria-live="polite">2 cycles</output>
            <script>
            (function() {
              var c = document.getElementById('wave'), ctx = c.getContext('2d'), f = document.getElementById('freq');
              var draw = function() {
                var n = Number(f.value);
                ctx.clearRect(0, 0, c.width, c.height);
                ctx.strokeStyle = '#ff9500'; ctx.lineWidth = 6; ctx.beginPath();
                for (var x = 0; x <= c.width; x += 4) {
                  var y = c.height / 2 + Math.sin(x / c.width * n * Math.PI * 2) * 90;
                  if (x === 0) { ctx.moveTo(x, y); } else { ctx.lineTo(x, y); }
                }
                ctx.stroke();
                document.getElementById('freq-out').textContent = n + (n === 1 ? ' cycle' : ' cycles');
              };
              f.addEventListener('input', draw);
              draw();
            })();
            </script>
            """
        ),
        .init(
            id: "startup-error",
            title: "Broken on start",
            expectation: "Script throws before drawing: the reader shows a tidy failure card.",
            html: """
            <div id="root"></div>
            <script>
            document.getElementById('chart').appendChild(document.createElement('div'));
            document.getElementById('root').textContent = 'Never shown';
            </script>
            """
        ),
        .init(
            id: "tap-error",
            title: "Breaks when tapped",
            expectation: "Works until tapped: the reader shows a small “stopped working” notice.",
            html: """
            <p>Tap to compute the yield.</p>
            <button id="go" type="button" style="min-height:44px">Compute yield</button>
            <output id="out" aria-live="polite">Waiting for input</output>
            <script>
            document.getElementById('go').addEventListener('click', function() {
              document.getElementById('out').textContent = bond.price / bond.face;
            });
            </script>
            """
        ),
        .init(
            id: "nan",
            title: "NaN at the slider’s edge",
            expectation: "Divides by zero at the minimum: the check reports the NaN.",
            html: """
            <label for="n">Periods</label>
            <input id="n" type="range" min="0" max="10" value="4" style="width:100%">
            <output id="avg" aria-live="polite">25 per period</output>
            <script>
            (function() {
              var n = document.getElementById('n');
              n.addEventListener('input', function() {
                document.getElementById('avg').textContent = (0 / Number(n.value)) + ' per period';
              });
            })();
            </script>
            """
        ),
        .init(
            id: "overflow",
            title: "Too wide for a phone",
            expectation: "A fixed 620px table: the check names the element.",
            html: """
            <table class="rates" style="width:620px;border-collapse:collapse">
              <tr><th>Maturity</th><th>Coupon</th><th>Price</th><th>Yield</th><th>Duration</th><th>Convexity</th></tr>
              <tr><td>2y</td><td>4.25%</td><td>99.81</td><td>4.35%</td><td>1.9</td><td>0.05</td></tr>
            </table>
            """
        ),
        .init(
            id: "inline-handlers",
            title: "Inline onclick",
            expectation: "The sandbox strips onclick=, so the button does nothing; the check says so.",
            html: """
            <p>Press to reveal the answer.</p>
            <button type="button" onclick="document.getElementById('a').hidden=false">Reveal</button>
            <p id="a" hidden>The answer is 42.</p>
            """
        ),
        .init(
            id: "unlabeled",
            title: "Unlabeled controls, silent results",
            expectation: "VoiceOver can’t name the controls or hear results; the check reports both.",
            html: """
            <input id="x" type="range" min="1" max="9" value="3" style="width:100%">
            <select id="unit"><option>Years</option><option>Months</option></select>
            <p id="r">3 years</p>
            <script>
            (function() {
              var update = function() {
                document.getElementById('r').textContent = document.getElementById('x').value + ' ' + document.getElementById('unit').value.toLowerCase();
              };
              document.getElementById('x').addEventListener('input', update);
              document.getElementById('unit').addEventListener('change', update);
            })();
            </script>
            """
        ),
        .init(
            id: "tall",
            title: "Taller than the screen",
            expectation: "Shows a faded preview with “Open full interactive”.",
            html: """
            <style>.row { padding: 14px; margin-bottom: 10px; border-radius: 10px; background: color-mix(in srgb, #5856d6 16%, transparent); }</style>
            \((1...12).map { "<div class=\"row\">Scenario \($0): rates move \($0 * 25) basis points and the portfolio reprices.</div>" }.joined(separator: "\n"))
            """
        ),
    ]
}
#endif
