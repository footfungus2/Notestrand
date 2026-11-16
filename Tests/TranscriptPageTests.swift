import WebKit
import XCTest
@testable import Notestrand

/// Runs the bundled transcript page in a real web view.
@MainActor
final class TranscriptPageTests: XCTestCase {
    private func loadPage() async throws -> WKWebView {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        web.loadFileURL(TranscriptHost.page, allowingReadAccessTo: TranscriptHost.page.deletingLastPathComponent())
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if (try? await web.evaluateJavaScript("typeof window.LH === 'object'")) as? Bool == true { return web }
        }
        throw XCTSkip("transcript page didn't load in time")
    }

    /// Mermaid loads on demand; tests that draw diagrams wait for it.
    private func loadPageWithMermaid() async throws -> WKWebView {
        let web = try await loadPage()
        _ = try await web.evaluateJavaScript("LH.loadMermaid(); 0")
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("typeof window.mermaid === 'object'")) as? Bool == true { return web }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw XCTSkip("Mermaid didn't load in time")
    }

    func testPageLoadsWithoutMermaidUntilNeeded() async throws {
        let web = try await loadPage()
        let early = try await web.evaluateJavaScript("typeof window.mermaid") as? String
        XCTAssertEqual(early, "undefined", "the 3 MB diagram library must not block the page load")
    }

    private func canDraw(_ web: WKWebView, _ src: String) async throws -> Bool {
        let arg = String(decoding: try JSONSerialization.data(withJSONObject: [src]), as: UTF8.self)
        return try await web.evaluateJavaScript("LH.canDraw(\(arg)[0])") as? Bool ?? false
    }

    func testMermaidRepairsCommonModelMistakes() async throws {
        let web = try await loadPageWithMermaid()
        // A real model reply: unquoted parentheses, a quoted subgraph title and an edge left dangling.
        let broken = """
        graph TD
            subgraph "BREAKEVEN ANALYSIS"
                direction LR
                A[Profit (π)] -->|line with positive slope| B[Contribution Margin Line]
                B -->|crosses x-axis at| C[Break-Even Point (BEP)]
                J[Product A] -->|CM = £15| K[Product B] -->|CM = £20|
                K -->|Weighted avg| L[CMR = 0.5]
            end
            style A fill:#e1f5fe,stroke:#01579b,stroke-width:2px
        """
        let ok = try await canDraw(web, broken)
        XCTAssertTrue(ok)
        let fine = try await canDraw(web, "graph LR\n  a[One] --> b[Two]")
        XCTAssertTrue(fine)
        let garbage = try await canDraw(web, "graph LR\n  a[[[ --> ")
        XCTAssertFalse(garbage)
    }

    func testChartSpecDrawsAndComputesReadouts() async throws {
        let web = try await loadPage()
        // The break-even example from the prompt: 4000 / (15 - 7) = 500 units.
        let spec = """
        {"title":"Break-even chart","x":{"label":"Units sold","min":0,"max":1000},"y":{"label":"£","min":0},
         "sliders":[{"name":"price","min":5,"max":30,"value":15},{"name":"vc","min":1,"max":20,"value":7},{"name":"fc","min":0,"max":8000,"value":4000}],
         "lines":[{"label":"Total revenue","fn":"price * x"},{"label":"Total costs","fn":"fc + vc * x"}],
         "shade":{"between":["Total revenue","Total costs"]},
         "points":[{"label":"Break-even","x":"fc / (price - vc)","y":"price * fc / (price - vc)"}],
         "readouts":[{"label":"Break-even output","value":"fc / (price - vc)","unit":"units"}]}
        """
        let js = """
        (function(){ try { eval(window.LH_CHART_SRC); LH.chartRenderer()(\(spec));
          var c = document.querySelector('canvas'), r = document.getElementById('lh-ro');
          return (c ? 'canvas' : 'no-canvas') + '|' + (r ? r.textContent : '') + '|' + document.querySelectorAll('input[type=range]').length;
        } catch (e) { return 'ERR ' + e.message } })()
        """
        let result = try await web.evaluateJavaScript(js) as? String ?? ""
        XCTAssertEqual(result, "canvas|Break-even output: 500 units|3")
    }

    func testChartBlockRendersInsideSandboxedFrame() async throws {
        let web = try await loadPage()
        let reply = "Chart:\n\n```chart\n{\"title\":\"BE\",\"x\":{\"min\":0,\"max\":1000},\"sliders\":[{\"name\":\"price\",\"min\":5,\"max\":30,\"value\":15},{\"name\":\"vc\",\"min\":1,\"max\":20,\"value\":7},{\"name\":\"fc\",\"min\":0,\"max\":8000,\"value\":4000}],\"lines\":[{\"label\":\"Revenue\",\"fn\":\"price*x\"},{\"label\":\"Costs\",\"fn\":\"fc+vc*x\"}],\"readouts\":[{\"label\":\"BEP\",\"value\":\"fc/(price-vc)\"}]}\n```\n"
        let state: [String: Any] = ["id": "t", "kind": "chat", "pending": [], "messages": [
            ["id": "a", "role": "assistant", "text": reply, "toolCalls": [], "isError": false],
        ]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)
        _ = try await web.evaluateJavaScript("LH.render(\(json)); 0")
        var height = 0
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 200_000_000)
            height = (try? await web.evaluateJavaScript("(function(){var f=document.querySelector('iframe.demo-frame');return f&&f.style.height?parseInt(f.style.height):0})()")) as? Int ?? 0
            if height > 0 { break }
        }
        // A drawn chart (300px canvas + sliders + readout) reports far more than an error message would.
        XCTAssertGreaterThan(height, 400)
    }

    func testMathRendersWithKaTeX() async throws {
        let web = try await loadPage()
        let state: [String: Any] = ["id": "t", "kind": "chat", "pending": [], "messages": [
            ["id": "a", "role": "assistant", "text": "Inline $x^2 + \\frac{1}{2}$ and\n\n$$\\int_0^1 x\\,dx = \\tfrac12$$\n\nand \\(\\sqrt{2}\\).", "toolCalls": [], "isError": false],
        ]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)
        _ = try await web.evaluateJavaScript("LH.render(\(json)); 0")
        let result = try await web.evaluateJavaScript("[katex.version, document.querySelectorAll('.katex').length, document.querySelectorAll('.katex-display').length, document.querySelectorAll('.katex-error').length].join('|')") as? String
        XCTAssertEqual(result, "0.16.47|3|1|0")
    }

    /// Content rules don't stop WebRTC, so the app removes it from every frame; a demo and a frame nested in it must both find it gone.
    func testDemosHaveNoWebRTC() async throws {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(TranscriptHost.noWebRTC)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        web.loadFileURL(TranscriptHost.page, allowingReadAccessTo: TranscriptHost.page.deletingLastPathComponent())
        var ready = false
        for _ in 0..<100 where !ready {
            try await Task.sleep(nanoseconds: 100_000_000)
            ready = (try? await web.evaluateJavaScript("typeof window.LH === 'object'")) as? Bool == true
        }
        guard ready else { throw XCTSkip("transcript page didn't load in time") }
        // The sandboxed frame can only report a height: 200 when WebRTC is gone in both frames, 300 more for each place it's found.
        let demo = """
        <div id="d"></div><script>
        var h = 200;
        if (typeof RTCPeerConnection !== "undefined" || typeof webkitRTCPeerConnection !== "undefined") h += 300;
        addEventListener("message", function (e) {
          if (typeof e.data !== "string" || e.data.indexOf("rtc:") !== 0) return;
          if (e.data !== "rtc:undefined") h += 300;
          document.getElementById("d").style.height = h + "px";
        });
        var f = document.createElement("iframe");
        f.style.cssText = "position:absolute;width:0;height:0;border:0";
        f.srcdoc = "<script>parent.postMessage('rtc:' + typeof RTCPeerConnection, '*')<\\/script>";
        document.body.appendChild(f);
        </script>
        """
        let state: [String: Any] = ["id": "t", "kind": "chat", "pending": [], "messages": [
            ["id": "a", "role": "assistant", "text": "```demo\n\(demo)\n```\n", "toolCalls": [], "isError": false],
        ]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)
        _ = try await web.evaluateJavaScript("LH.render(\(json)); 0")
        var height = 0
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 200_000_000)
            height = (try? await web.evaluateJavaScript("(function(){var f=document.querySelector('iframe.demo-frame');return f&&f.style.height?parseInt(f.style.height):0})()")) as? Int ?? 0
            if height >= 190 { break }
        }
        XCTAssertGreaterThanOrEqual(height, 190, "the demo didn't report back")
        XCTAssertLessThan(height, 400, "WebRTC is still reachable from a demo frame")
    }

    func testActionBarsOnlyOfferRewindOnTheLatestTurn() async throws {
        let web = try await loadPage()
        let msgs: [[String: Any]] = [
            ["id": "u1", "role": "user", "text": "hi", "toolCalls": [], "isError": false, "created": 800_000_000.0],
            ["id": "a1", "role": "assistant", "text": "hello", "toolCalls": [], "isError": false, "created": 800_000_010.0],
            ["id": "u2", "role": "user", "text": "more", "toolCalls": [], "isError": false],
            ["id": "a2", "role": "assistant", "text": "sure", "toolCalls": [], "isError": false],
        ]
        let state: [String: Any] = ["id": "bars", "kind": "chat", "pending": [], "running": false, "messages": msgs]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)
        let r = try await web.evaluateJavaScript("""
        LH.render(\(json));
        Array.from(document.querySelectorAll('.actions')).map(function(b){
          return Array.from(b.querySelectorAll('.act')).map(function(x){return x.getAttribute('aria-label')+(x.classList.contains('on')?'*':'')}).join(',') + (b.querySelector('.time')?'+t':'');
        }).join(' | ')
        """) as? String
        XCTAssertEqual(r, "Edit in a new branch,Copy message+t | Copy reply,Read aloud+t | Send again,Edit message,Copy message | Copy reply,Read aloud,Regenerate reply")
    }
}
