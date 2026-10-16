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
        print("Segments checks passed")
    }
}
