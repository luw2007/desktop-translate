@main
struct SegmentsChecks {
    static func main() {
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
        }
        func translated(_ plan: TranslationPlan) -> String {
            plan.rendered(translations: Dictionary(uniqueKeysWithValues: plan.requests.map { ($0.id, "译文") }))
        }

        let endings = "This is prose.\r\n\r\nMore prose here.\rLast prose line.\n"
        let endingsPlan = TranslationPlan(text: endings)
        expect(endingsPlan.rendered(translations: [:]) == endings, "Mixed line endings must reconstruct exactly")
        expect(translated(endingsPlan) == "译文\r\n\r\n译文\r译文\n", "Translation must preserve blank lines and separators")
        expect(TranslationPlan(text: "").rendered(translations: [:]) == "", "Empty input")

        let fenced = "```swift\r\nlet value = 1\r\nEnglish inside fence\r\n```\r\nThis explains the result.\n"
        let fencePlan = TranslationPlan(text: fenced)
        expect(fencePlan.requests.map { $0.text } == ["This explains the result."], "Only prose after fence is requested")
        expect(translated(fencePlan) == "```swift\r\nlet value = 1\r\nEnglish inside fence\r\n```\r\n译文\n", "Fence contents are literal")
        let tildeFence = "~~~~\nEnglish stays here\n~~~\nStill inside fence\n~~~~\nUseful explanation here"
        expect(TranslationPlan(text: tildeFence).requests.map { $0.text } == ["Useful explanation here"], "Short fence cannot close longer fence")

        let protected = "Read `git status` from /tmp/output.txt and https://example.com/help now.\n"
        let protectedPlan = TranslationPlan(text: protected)
        expect(translated(protectedPlan) == "译文 `git status` 译文 /tmp/output.txt 译文 https://example.com/help 译文\n", "Inline code, paths, URLs and surrounding spaces stay exact")
        expect(protectedPlan.rendered(translations: [:]) == protected, "Protected tokens reconstruct unchanged")
        let doubleTicks = TranslationPlan(text: "Read ``a ` b`` for details.")
        expect(translated(doubleTicks) == "译文 ``a ` b`` 译文", "Backtick delimiter length is respected")
        let unmatched = TranslationPlan(text: "Read `unfinished code now")
        expect(translated(unmatched) == "译文 `unfinished code now", "Unmatched backtick protects remainder")

        let partial = TranslationPlan(text: "First explanatory line.\nSecond explanatory line.")
        expect(partial.rendered(translations: [partial.requests[0].id: "第一行"]) == "第一行\nSecond explanatory line.", "Missing entry retains original fragment")

        let commands = "$ git status\nuser@host:~$ cat notes.txt\n% echo hello\ngit diff --stat\nsudo brew install tool\ndiff --git a/file b/file\n@@ -1 +1 @@\n- removed explanatory words\n+ added explanatory words\nlet value = 1\nreturn value;\n"
        let commandsPlan = TranslationPlan(text: commands)
        expect(commandsPlan.requests.isEmpty, "Prompts, commands, diffs and source rows have no requests")
        expect(translated(commandsPlan) == commands, "Command rows remain exact")

        let wrapped = "  This explanation wraps\n    onto another line\n    naturally\n\tIndented English explanation.\n这是中文说明。\n"
        let wrappedPlan = TranslationPlan(text: wrapped)
        expect(wrappedPlan.requests.map { $0.text } == ["This explanation wraps", "onto another line", "naturally", "Indented English explanation."], "Indented prose and short continuations are accepted")
        expect(translated(wrappedPlan) == "  译文\n    译文\n    译文\n\t译文\n这是中文说明。\n", "Indentation and Chinese-only content remain exact")

        // Bullets are prose outside diff context (zh and en); real unified-diff rows stay protected.
        let bullets = "- 受保护文字不翻译：命令提示符、命令、代码、路径。\n- Protected text is not translated here.\n* 另一个中文项目说明\n"
        let zhBullets = TranslationPlan(text: bullets, unicode: true)
        expect(zhBullets.requests.map { $0.text } == ["受保护文字不翻译：命令提示符、命令、代码、路径。", "Protected text is not translated here.", "另一个中文项目说明"],
               "Prose bullets in zh and en are translatable: \(zhBullets.requests)")
        expect(TranslationPlan(text: "- Protected text is not translated here.\n").requests.count == 1, "English bullet translatable in English mode")
        expect(TranslationPlan(text: "- --flag value\n- 42\n+ x = 1\n", unicode: true).requests.isEmpty, "Option/number/code bullets stay original")
        let hunk = "@@ -1,2 +1,2 @@\n- 删除了这一行中文说明\n+ 新增了这一行中文说明\n 上下文说明文字在这里\n"
        expect(TranslationPlan(text: hunk, unicode: true).requests.allSatisfy { !$0.text.contains("删除") && !$0.text.contains("新增") }, "Diff hunk +/- rows stay protected")
        let headerless = "- removed explanatory words\n+ added explanatory words\n"
        expect(TranslationPlan(text: headerless).requests.isEmpty, "Adjacent -/+ pair without header stays protected")
        let afterBlank = "diff --git a/f b/f\n- old line here now\n\n- 普通中文项目说明文字\n"
        expect(TranslationPlan(text: afterBlank, unicode: true).requests.map { $0.text } == ["普通中文项目说明文字"], "Diff context ends at a blank line")

        // Short natural-language labels, titles and status text translate (zh and en); machine text still does not.
        func reqs(_ text: String, unicode: Bool = true) -> [String] { TranslationPlan(text: text, unicode: unicode).requests.map { $0.text } }
        expect(reqs("Complete") == ["Complete"] && reqs("Complete", unicode: false) == ["Complete"], "Single capitalised word is a label")
        expect(reqs("✓ Complete") == ["Complete"], "Decoration glyph stays outside the request")
        expect(reqs("工作区") == ["工作区"] && reqs("新建终端") == ["新建终端"], "Short Chinese labels translate")
        expect(reqs("Build succeeded in 3 seconds") == ["Build succeeded in 3 seconds"], "Status sentence translates")
        expect(reqs("BUILD SUCCEEDED") == ["BUILD SUCCEEDED"], "Upper-case phrase translates")
        expect(reqs("## Release notes") == ["Release notes"], "Markdown heading body translates")
        expect(reqs("main | 3 files changed") == ["main | 3 files changed"], "Status separator is not a pipeline")
        expect(reqs("for more details see the guide") == ["for more details see the guide"], "Sentence starting with a soft keyword translates")
        expect(reqs("go to the settings page") == ["go to the settings page"], "Ambiguous command word without arguments is prose")
        expect(reqs("Settings; Preferences and more things") == ["Settings; Preferences and more things"], "Prose semicolon is allowed")
        for machine in ["/usr/local/bin/tool", "~/src/app", "https://example.com/a", "a1b2c3d4e5f6", "42", "12:30:45", "--verbose", "-x", "snake_case_name",
                        "camelCaseName", "my.module.name", "192.168.1.10", "host.example.com", "user@host", "$ git status", "git status", "npm run build",
                        "ls -la", "go build ./...", "make all", "cat file.txt", "let x = 1", "import Foundation", "return value;", "for i in 1..3 {",
                        "if (x) {", "@@ -1 +1 @@", "+ added line", "...", "---", "❯ git status", "v1.2.3", "main", "x"] {
            expect(reqs(machine).isEmpty, "Machine text stays original: \(machine)")
        }
        // Skip reasons: counted per rule, never with text.
        func reason(_ text: String) -> SkipReason { TranslationPlan(text: text, unicode: true).skipReason }
        expect(reason("/usr/local/bin/tool") == .path && reason("https://example.com/a") == .url && reason("a1b2c3d4e5f6") == .hash
               && reason("--verbose") == .flag && reason("snake_case_name") == .identifier && reason("user@host") == .host,
               "Reasons are named")
        expect(reason("$ git status") == .prompt && reason("git status") == .command && reason("12:30:45") == .number && reason("...") == .symbols
               && reason("main") == .short && reason("let x = 1") == .code, "Reasons: prompt/command/number/symbols/short/code")

        // Chinese prose with embedded technical tokens translates (auto/zh source); the tokens are protected inside the request.
        let quoted = [
            "- 两个译文框重叠时，阅读顺序靠前的保留完整原行，靠后的把重叠部分切掉。剩下的部分要至少 6pt 见方，取最大的一块，再走正常的流程：常规字体 → 扩展 → 窄字体缩到 9pt → 半透明覆盖 →",
            "- 仍然处理不了的，比如被前一个整个包住、或者和受保护文字重叠，仍算 C。但现在会画橙色标记，点开能看全文，以前什么都不画。",
            "- 两条译文不会叠在一起画。",
            "- 以 for/if/from/return/case/while 开头的句子。",
            "- 以 go/make/cat/env 开头的行，这些也是普通英文单词。",
            "- 现在会翻译：首字母大写、3 个字母以上的单词；全大写的多词短语；…",
            "- 仍然跳过：路径、URL、哈希、数字和时间、参数、标识符（下划线、驼峰、点号分隔）、主机名和 IP、纯符号、代码、diff、代码块，以及提示符后的命令（包括 ❯ git status）。",
            "- 英文来源下的纯中文行仍然跳过，这条行为没变。",
        ]
        for line in quoted {
            let plan = TranslationPlan(text: line, unicode: true)
            expect(plan.requests.count >= 1 && plan.skipReason == .empty, "Chinese bullet translates: \(line.prefix(12)) \(plan.skipReason)")
            expect(plan.rendered(translations: Dictionary(uniqueKeysWithValues: plan.requests.map { ($0.id, $0.text) })) == line, "Round trip keeps bullet: \(line.prefix(12))")
        }
        let units = TranslationPlan(text: "- 至少 6pt 见方，缩到 9pt", unicode: true)
        expect(units.requests.count == 1 && units.embeddedTokens.values.flatMap { $0 }.sorted() == ["6pt", "9pt"], "Units are embedded protected tokens: \(units.embeddedTokens)")
        let inline = TranslationPlan(text: "- 运行 `git status` 查看 https://a.b/c 与 foo_bar 的差异", unicode: true)
        expect(inline.requests.count == 1 && Set(inline.embeddedTokens.values.flatMap { $0 }) == ["`git status`", "https://a.b/c", "foo_bar"],
               "Inline code, URL and identifier are protected inside one request: \(inline.embeddedTokens)")
        let prompt = TranslationPlan(text: "- 以及提示符后的命令（包括 ❯ git status）。", unicode: true)
        expect(prompt.requests.count == 1 && prompt.embeddedTokens.values.flatMap { $0 } == ["❯ git status"], "Prompt command is protected: \(prompt.embeddedTokens)")
        expect(reqs("-两个译文不会叠在一起画。") == ["两个译文不会叠在一起画。"], "OCR-glued bullet dash is a bullet, not a flag/number")
        expect(reqs("- 6pt") .isEmpty && reqs("- --flag").isEmpty && reqs("-12").isEmpty && reqs("echo 你好世界").isEmpty,
               "Genuinely machine bullets stay original")
        expect(reqs("curl is a tool for transferring data from servers.") == ["curl is a tool for transferring data from servers."],
               "English sentence that starts with a command word translates")
        // English source keeps the old rule: a pure Chinese line is skipped.
        expect(reqs("两条译文不会叠在一起画。", unicode: false).isEmpty, "English source skips pure Chinese lines")
        // Wrapped bullet: the indented continuation merges into the bullet's request.
        let wrappedBullet = TranslationPlan(text: "- 但现在会画橙色\n  标记，点开能看全文", visualContinuationLines: [1], unicode: true)
        expect(wrappedBullet.requests.map { $0.text } == ["但现在会画橙色 标记，点开能看全文"], "Indented continuation joins its bullet: \(wrappedBullet.requests)")
        expect(TranslationPlan.startsListItem("- 两条") && TranslationPlan.startsListItem("-两条") && !TranslationPlan.startsListItem("标记，点开"),
               "List item start never continues the previous line")
        print("Segments checks passed")
    }
}
