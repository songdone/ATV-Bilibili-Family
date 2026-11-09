import FamilyCore
import Foundation
import CoreFoundation
import CryptoKit

/// Offline validation of declarations, not proof of human review or copyright.
/// No partial pools: one invalid bank blocks loading and names the offending file.
final class FamilyQuestionBank {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private struct Entry {
        let question: QuizQuestion
        let curriculum: String
        let stage: String
        let system: String
        let semester: String
        let version: String
        let chapter: String
    }
    private let entries: [Entry]
    var questions: [QuizQuestion] { entries.map(\.question) }
    struct CatalogItem: Codable {
        let curriculum: String
        let stage: String
        let system: String
        let grade: Int
        let semester: String
        let subject: String
        let textbookVersion: String
        let chapters: [String]
    }
    /// Validated availability, not a claim of complete textbook coverage.
    var catalog: [CatalogItem] {
        let groups = Dictionary(grouping: entries) {
            [$0.curriculum, $0.stage, $0.system, String($0.question.grade), $0.semester, $0.question.subject, $0.version]
        }
        return groups.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { key in
            CatalogItem(curriculum: key[0], stage: key[1], system: key[2], grade: Int(key[3])!,
                semester: key[4], subject: key[5], textbookVersion: key[6],
                chapters: Set(groups[key]!.map(\.chapter)).sorted())
        }
    }
    private init(entries: [Entry]) { self.entries = entries }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    private static func object(_ value: Any?, _ keys: Set<String>, _ at: String) throws -> [String: Any] {
        guard let result = value as? [String: Any], Set(result.keys) == keys else {
            throw Failure(message: "\(at)：字段缺失或存在未知字段")
        }
        return result
    }
    private static func text(_ value: Any?, _ at: String) throws -> String {
        guard let result = value as? String, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "\(at)：需要非空文本")
        }
        return result
    }
    private static func integer(_ value: Any?, _ at: String) throws -> Int {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(n), let result = Int(n.stringValue) else {
            throw Failure(message: "\(at)：需要整数")
        }
        return result
    }
    private static func boolean(_ value: Any?, _ at: String) throws -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
            throw Failure(message: "\(at)：需要布尔值")
        }
        return n.boolValue
    }
    private static func strings(_ value: Any?, _ at: String) throws -> [String] {
        guard let array = value as? [Any], !array.isEmpty else {
            throw Failure(message: "\(at)：需要非空列表")
        }
        let result = try array.map { try text($0, at) }
        try check(Set(result).count == result.count, "\(at)：重复值")
        return result
    }
    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // JSONSerialization otherwise silently accepts duplicate object keys. Walk
    // syntax first, delegating actual JSON validity/unescaping to Foundation.
    private struct KeyScanner {
        let bytes: [UInt8]
        var i = 0
        mutating func space() { while i < bytes.count && [9, 10, 13, 32].contains(bytes[i]) { i += 1 } }
        mutating func string() throws -> String {
            let start = i
            i += 1
            while i < bytes.count {
                if bytes[i] == 92 { i += 2; continue }
                if bytes[i] == 34 {
                    i += 1
                    return try JSONSerialization.jsonObject(with: Data(bytes[start..<i]), options: .fragmentsAllowed) as! String
                }
                i += 1
            }
            throw Failure(message: "JSON 字符串未结束")
        }
        mutating func value(_ depth: Int = 0) throws {
            try check(depth < 100, "JSON 嵌套过深")
            space()
            guard i < bytes.count else { throw Failure(message: "JSON 不完整") }
            if bytes[i] == 34 { _ = try string(); return }
            if bytes[i] == 123 || bytes[i] == 91 {
                let isObject = bytes[i] == 123
                let end: UInt8 = isObject ? 125 : 93
                i += 1
                space()
                var keys = Set<String>()
                if i < bytes.count && bytes[i] == end { i += 1; return }
                while i < bytes.count {
                    if isObject {
                        space()
                        try check(i < bytes.count && bytes[i] == 34, "JSON 对象键错误")
                        let key = try string()
                        try check(keys.insert(key).inserted, "JSON 重复键：\(key)")
                        space()
                        try check(i < bytes.count && bytes[i] == 58, "JSON 缺少冒号")
                        i += 1
                    }
                    try value(depth + 1)
                    space()
                    guard i < bytes.count else { break }
                    if bytes[i] == end { i += 1; return }
                    try check(bytes[i] == 44, "JSON 分隔符错误")
                    i += 1
                }
                throw Failure(message: "JSON 容器未结束")
            }
            let start = i
            while i < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[i]) { i += 1 }
            try check(i > start, "JSON 值错误")
        }
    }
    private static func json(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        var scanner = KeyScanner(bytes: Array(data))
        try scanner.value()
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "JSON 顶层必须是对象")
        }
        return result
    }

    static func load(bundle: Bundle = .main) throws -> FamilyQuestionBank {
        var urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: "QuestionBank") ?? []
        // Preserve flattened synchronized-group resources. The only known unrelated
        // root JSON is explicitly excluded; malformed bank candidates are NOT skipped.
        urls += (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent != "SupportConfig.json" }
        var indexURL: URL?
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let directory = documents.appendingPathComponent("QuestionBank", isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.path) {
                let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                indexURL = children.first { $0.lastPathComponent == "book-index.json" }
                urls += children.filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent != "book-index.json" }
            }
        }
        return try load(urls: urls, indexURL: indexURL)
    }

    static func load(urls: [URL], indexURL: URL? = nil) throws -> FamilyQuestionBank {
        let unique = Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }).sorted { $0.path < $1.path }
        try check(!unique.isEmpty, "MISSING_BANK：未发现题库文件")
        var index: [String: [String: Any]] = [:]
        if let indexURL {
            let raw = try json(indexURL)
            guard let books = raw["books"] as? [[String: Any]] else { throw Failure(message: "教材索引缺少 books") }
            for book in books {
                let id = try text(book["book_id"], "book_id")
                try check(index[id] == nil, "索引 book_id 重复")
                let repo = try text(book["repo"], "repo")
                let commit = try text(book["commit"], "commit")
                let path = try text(book["path"], "path")
                try check(repo == raw["repo"] as? String && commit == raw["commit"] as? String &&
                          id == digest(Data("\(repo)@\(commit):\(path)".utf8)), "教材索引来源不一致")
                index[id] = book
            }
        }
        var bankIDs = Set<String>(), questionIDs = Set<String>()
        var entries: [Entry] = []
        for url in unique {
            do {
                let bank = try json(url)
                let id = try text(bank["bankId"], "bankId")
                try check(bankIDs.insert(id).inserted, "重复 bankId：\(id)")
                let validated = try validate(bank, index: index)
                for entry in validated {
                    try check(questionIDs.insert(entry.question.id).inserted, "全局重复 question_id：\(entry.question.id)")
                }
                entries += validated
            } catch { throw Failure(message: "\(url.path)：\(error.localizedDescription)") }
        }
        return FamilyQuestionBank(entries: entries)
    }

    private static func validate(_ value: [String: Any], index: [String: [String: Any]]) throws -> [Entry] {
        let bank = try object(value, ["schemaVersion", "bankId", "curriculum", "testOnly", "licenseStatus", "reviewEvidence", "questions"], "bank")
        try check(try integer(bank["schemaVersion"], "schemaVersion") == 1, "未知 schemaVersion")
        try check(matches(try text(bank["bankId"], "bankId"), "^[A-Za-z0-9_.-]+$"), "bankId 格式错误")
        try check(try !boolean(bank["testOnly"], "testOnly"), "testOnly 题库禁止进入运行池")
        let curriculum = try object(bank["curriculum"], ["kind", "alignment", "description"], "curriculum")
        let kind = try text(curriculum["kind"], "curriculum.kind")
        try check(["general_knowledge", "exact_textbook"].contains(kind), "未知 curriculum")
        try check(curriculum["alignment"] as? String == (kind == "general_knowledge" ? "not_exact_textbook" : "exact_textbook"), "curriculum alignment 不一致")
        _ = try text(curriculum["description"], "curriculum.description")
        guard let rawQuestions = bank["questions"] as? [[String: Any]], !rawQuestions.isEmpty else {
            throw Failure(message: "题库 questions 为空或无效")
        }
        var result: [Entry] = []
        for raw in rawQuestions {
            let q = try object(raw, ["question_id", "stage", "system", "grade", "semester", "subject", "textbookVersion", "chapter", "knowledgePoints", "difficulty", "prompt", "type", "options", "answer", "explanation", "sourceBook", "sourcePage", "reviewStatus"], "question")
            let id = try text(q["question_id"], "question_id")
            try check(matches(id, "^[A-Za-z0-9_.-]+$"), "question_id 格式错误")
            try check(q["reviewStatus"] as? String == "approved", "\(id)：含未审/拒绝题目")
            let stage = try text(q["stage"], id + ".stage"), system = try text(q["system"], id + ".system")
            let grade = try integer(q["grade"], id + ".grade")
            let validGrade = (stage == "primary" && ["6_3", "5_4"].contains(system) && (1...(system == "5_4" ? 5 : 6)).contains(grade)) ||
                (stage == "junior_secondary" && ["6_3", "5_4"].contains(system) && ((system == "5_4" ? 6 : 7)...9).contains(grade)) ||
                (stage == "senior_secondary" && ["6_3", "5_4", "not_applicable"].contains(system) && (10...12).contains(grade))
            try check(validGrade, "\(id)：学段/学制/年级无效（runtime 仅支持 K12）")
            let semester = try text(q["semester"], "semester")
            try check(["first", "second", "full_year"].contains(semester), "\(id)：学期无效")
            let subject = try text(q["subject"], "subject"), version = try text(q["textbookVersion"], "textbookVersion")
            try check((version == "general_knowledge") == (kind == "general_knowledge"), "\(id)：课程与版本不一致")
            let chapter = try text(q["chapter"], "chapter")
            _ = try strings(q["knowledgePoints"], "knowledgePoints")
            let difficulty = try text(q["difficulty"], "difficulty")
            try check(["easy", "medium", "hard"].contains(difficulty), "\(id)：难度无效")
            let type = try text(q["type"], "type")
            try check(["single_choice", "true_false"].contains(type), "\(id)：runtime 仅支持单选/判断")
            guard let rawOptions = q["options"] as? [[String: Any]], rawOptions.count >= 2 else { throw Failure(message: "\(id)：选项无效") }
            let options: [QuizOption] = try rawOptions.map {
                let o = try object($0, ["id", "text"], "option")
                let optionID = try text(o["id"], "option.id")
                try check(matches(optionID, "^[A-Za-z0-9_-]+$"), "option ID 格式错误")
                return QuizOption(id: optionID, text: try text(o["text"], "option.text"))
            }
            try check(Set(options.map(\.id)).count == options.count && Set(options.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }).count == options.count, "\(id)：重复选项 ID/文本")
            if type == "true_false" { try check(Set(options.map(\.id)) == ["true", "false"], "判断题必须使用 true/false") }
            let answer = try text(q["answer"], "answer")
            try check(options.contains { $0.id == answer }, "\(id)：答案不在选项中")
            let sourceNull = q["sourceBook"] is NSNull, pageNull = q["sourcePage"] is NSNull
            try check(sourceNull == pageNull, "\(id)：书籍与页码必须配对")
            try check(kind != "exact_textbook" || !sourceNull, "\(id)：精确教材缺少书籍/页码")
            var page: Int?
            if !sourceNull {
                let source = try object(q["sourceBook"], ["repo", "commit", "path", "blobsha", "book_id"], "sourceBook")
                let repo = try text(source["repo"], "repo"), commit = try text(source["commit"], "commit")
                let path = try text(source["path"], "path"), blob = try text(source["blobsha"], "blobsha")
                let bookID = try text(source["book_id"], "book_id")
                try check(matches(repo, "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") && matches(commit, "^[0-9a-f]{40}$") && matches(blob, "^[0-9a-f]{40}$"), "来源标识无效")
                try check(!path.hasPrefix("/") && !path.contains("\\") && !path.components(separatedBy: "/").contains(".."), "来源路径无效")
                try check(bookID == digest(Data("\(repo)@\(commit):\(path)".utf8)), "source book_id 不一致")
                guard let book = index[bookID], let metadata = book["metadata"] as? [String: Any] else { throw Failure(message: "\(id)：缺少固定教材索引，无 fallback") }
                for (key, value) in source { try check(value as? String == book[key] as? String, "来源与索引不一致：\(key)") }
                try check(book["format"] as? String != "pdf_part", "分片 PDF 不能作为已审来源")
                for key in ["stage", "system", "grade", "semester", "subject", "textbookVersion"] {
                    guard let known = metadata[key] else { throw Failure(message: "索引缺少 metadata.\(key)") }
                    if !(known is NSNull) { try check(NSDictionary(dictionary: ["v": known]).isEqual(to: ["v": q[key]!]), "来源维度不一致：\(key)") }
                }
                let sourcePage = try object(q["sourcePage"], ["pdfPage", "printedPage"], "sourcePage")
                page = try integer(sourcePage["pdfPage"], "pdfPage")
                try check(page! > 0, "页码必须大于零")
                if !(sourcePage["printedPage"] is NSNull) { _ = try text(sourcePage["printedPage"], "printedPage") }
            }
            result.append(Entry(question: QuizQuestion(id: id, grade: grade, subject: subject, difficulty: difficulty,
                prompt: try text(q["prompt"], "prompt"), options: options, answerID: answer,
                explanation: try text(q["explanation"], "explanation"), sourcePage: page,
                sourceMetadata: QuizSourceMetadata(title: sourceNull ? "通用知识练习（非教材同步）" : nil,
                    edition: version, chapter: chapter,
                    reference: (q["sourceBook"] as? [String: Any])?["path"] as? String)),
                curriculum: kind, stage: stage, system: system, semester: semester, version: version, chapter: chapter))
        }
        let evidence = try object(bank["reviewEvidence"], ["reviewedBy", "reviewedAt", "answersVerified", "provenanceVerified", "licenseVerified", "notes", "reviewType", "humanReviewed", "textbookAlignmentVerified", "licenseBasis", "reviewedQuestionIDs", "contentSHA256"], "reviewEvidence")
        let reviewer = try text(evidence["reviewedBy"], "reviewedBy"), notes = try text(evidence["notes"], "notes")
        _ = try text(evidence["licenseBasis"], "licenseBasis")
        try check(try boolean(evidence["answersVerified"], "answersVerified") && boolean(evidence["provenanceVerified"], "provenanceVerified"), "审核声明不完整")
        let license = try boolean(evidence["licenseVerified"], "licenseVerified")
        let human = try boolean(evidence["humanReviewed"], "humanReviewed")
        let alignment = try boolean(evidence["textbookAlignmentVerified"], "textbookAlignmentVerified")
        let reviewType = try text(evidence["reviewType"], "reviewType")
        if reviewType == "ai" {
            try check(!human && !alignment && !license && kind == "general_knowledge" && bank["licenseStatus"] as? String == "ai_assessed", "AI 评估不能冒充人工/教材/许可审定")
            try check(reviewer.contains("AI") && ["AI核对+结构校验", "非教师/出版社审定", "未逐教材匹配"].allSatisfy { notes.contains($0) }, "AI 审核缺少限制声明")
        } else {
            try check(reviewType == "human" && human && license && bank["licenseStatus"] as? String == "cleared", "人工许可声明不完整")
            try check(kind != "exact_textbook" || alignment, "精确教材未核对")
        }
        let stamp = try text(evidence["reviewedAt"], "reviewedAt")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: stamp)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? formatter.date(from: stamp), date <= Date() else { throw Failure(message: "审核日期无效或在未来") }
        try check(Set(try strings(evidence["reviewedQuestionIDs"], "reviewedQuestionIDs")) == Set(result.map { $0.question.id }), "审核未覆盖全部题号")
        let payload = try JSONSerialization.data(withJSONObject: ["curriculum": curriculum, "questions": rawQuestions], options: [.sortedKeys, .withoutEscapingSlashes])
        try check(try text(evidence["contentSHA256"], "contentSHA256") == digest(payload), "审核内容摘要不一致；修改后需重新核对")
        return result
    }

    private static func configured(_ value: String?, _ field: String) throws -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !["待设置", "未设置", "unknown", "other"].contains(value) else {
            throw Failure(message: "MISSING_CONFIG：请家长配置 \(field)")
        }
        return value
    }
    func questions(for profile: ViewerProfile) throws -> [QuizQuestion] {
        let c = profile.curriculum
        // Academic year is optional legacy profile information; banks have no year dimension.
        let stage = try Self.configured(c.schoolStage, "学段")
        let system = try Self.configured(c.schoolSystem, "学制")
        let semester = try Self.configured(c.semester, "学期")
        let canonicalStage = ["小学": "primary", "初中": "junior_secondary", "高中": "senior_secondary"][stage] ?? stage
        let canonicalSystem = ["六三": "6_3", "六三制": "6_3", "五四": "5_4", "五四制": "5_4"][system] ?? system
        let canonicalSemester = ["上": "first", "下": "second", "上学期": "first", "下学期": "second", "全年": "full_year", "全学年": "full_year"][semester] ?? semester
        try Self.check((1...12).contains(c.grade), "MISSING_CONFIG：年级")
        try Self.check(!c.subjects.isEmpty && Set(c.subjects).count == c.subjects.count, "MISSING_CONFIG：科目未设置或重复")
        var matching: [QuizQuestion] = []
        for subject in c.subjects {
            _ = try Self.configured(subject, "科目")
            let configuredVersion = try Self.configured(c.subjectTextbookVersions[subject], "\(subject)教材版本")
            let version = configuredVersion == "通用知识版" ? "general_knowledge" : configuredVersion
            let kind = version == "general_knowledge" ? "general_knowledge" : "exact_textbook"
            guard let chapters = c.learnedChapters[subject], !chapters.isEmpty, Set(chapters).count == chapters.count else {
                throw Failure(message: "MISSING_CONFIG：请家长配置 \(subject)已学章节")
            }
            for chapter in chapters { _ = try Self.configured(chapter, "已学章节") }
            try Self.check(!chapters.contains("*") || chapters == ["*"], "MISSING_CONFIG：全章节不能与具体章节混用")
            let pool = entries.filter {
                $0.curriculum == kind && $0.stage == canonicalStage && $0.system == canonicalSystem &&
                $0.question.grade == c.grade && $0.question.subject == subject && $0.version == version &&
                ($0.semester == canonicalSemester || (kind == "general_knowledge" &&
                    ["first", "second", "full_year"].contains(canonicalSemester) &&
                    ($0.semester == "full_year" || canonicalSemester == "full_year"))) &&
                (chapters == ["*"] || chapters.contains($0.chapter))
            }
            try Self.check(!pool.isEmpty, "MISSING_POOL：\(subject)的课程/学段/学制/年级/学期/版本/已学章节无匹配题目，不跨版本回退")
            matching += pool.map(\.question)
        }
        return matching.sorted { $0.id < $1.id }
    }
    func makeRound(for profile: ViewerProfile, perRound: Int) throws -> [QuizQuestion] {
        try Self.check((1...10).contains(perRound), "MISSING_CONFIG：每轮题数须为 1–10")
        let pool = try questions(for: profile)
        try Self.check(pool.count >= perRound, "INSUFFICIENT_POOL：需要 \(perRound) 题，实际 \(pool.count) 题；不会减少题数")
        // Also shuffle presentation order each round; choosing the first button is
        // not equivalent to selecting the bank's A answer on every question.
        return pool.shuffled().prefix(perRound).map {
            QuizQuestion(id: $0.id, grade: $0.grade, subject: $0.subject, difficulty: $0.difficulty,
                prompt: $0.prompt, options: $0.options.shuffled(), answerID: $0.answerID,
                explanation: $0.explanation, sourcePage: $0.sourcePage, sourceMetadata: $0.sourceMetadata)
        }
    }
}
