import Commandant
#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Result
import SwiftLintFramework
import SwiftyTextTable

private func print(ruleDescription desc: RuleDescription) {
    print("\(desc.consoleDescription)")

    if !desc.triggeringExamples.isEmpty {
        func indent(_ string: String) -> String {
            return string.components(separatedBy: "\n")
                .map { "    \($0)" }
                .joined(separator: "\n")
        }
        print("\nTriggering Examples (violation is marked with '↓'):")
        for (index, example) in desc.triggeringExamples.enumerated() {
            print("\nExample #\(index + 1)\n\n\(indent(example))")
        }
    }
}

struct RulesCommand: CommandProtocol {
    let verb = "rules"
    let function = "Display the list of rules and their identifiers"

    func run(_ options: RulesOptions) -> Result<(), CommandantError<()>> {
        if let ruleID = options.ruleID {
            guard let rule = masterRuleList.list[ruleID] else {
                return .failure(.usageError(description: "No rule with identifier: \(ruleID)"))
            }

            print(ruleDescription: rule.description)
            return .success(())
        }

        if options.onlyDisabledRules && options.onlyEnabledRules {
            return .failure(.usageError(description: "You can't use --disabled and --enabled at the same time."))
        }

        let configuration = Configuration(options: options)
        let rules = ruleList(for: options, configuration: configuration)

        print(TextTable(ruleList: rules, configuration: configuration).render())
        return .success(())
    }

    private func ruleList(for options: RulesOptions, configuration: Configuration) -> RuleList {
        guard options.onlyEnabledRules || options.onlyDisabledRules else {
            return masterRuleList
        }

        let filtered: [Rule.Type] = masterRuleList.list.compactMap { ruleID, ruleType in
            let configuredRule = configuration.rules.first { rule in
                return type(of: rule).description.identifier == ruleID
            }

            if options.onlyEnabledRules && configuredRule == nil {
                return nil
            } else if options.onlyDisabledRules && configuredRule != nil {
                return nil
            }

            return ruleType
        }

        return RuleList(rules: filtered)
    }
}

struct RulesOptions: OptionsProtocol {
    fileprivate let ruleID: String?
    let configurationFile: String
    fileprivate let onlyEnabledRules: Bool
    fileprivate let onlyDisabledRules: Bool

    // swiftlint:disable line_length
    static func create(_ configurationFile: String) -> (_ ruleID: String) -> (_ onlyEnabledRules: Bool) -> (_ onlyDisabledRules: Bool) -> RulesOptions {
        return { ruleID in { onlyEnabledRules in { onlyDisabledRules in
            self.init(ruleID: (ruleID.isEmpty ? nil : ruleID),
                      configurationFile: configurationFile,
                      onlyEnabledRules: onlyEnabledRules,
                      onlyDisabledRules: onlyDisabledRules)
        }}}
    }

    static func evaluate(_ mode: CommandMode) -> Result<RulesOptions, CommandantError<CommandantError<()>>> {
        return create
            <*> mode <| configOption
            <*> mode <| Argument(defaultValue: "",
                                 usage: "the rule identifier to display description for")
            <*> mode <| Switch(flag: "e",
                               key: "enabled",
                               usage: "only display enabled rules")
            <*> mode <| Switch(flag: "d",
                               key: "disabled",
                               usage: "only display disabled rules")
    }
}

// MARK: - SwiftyTextTable

protocol ConsoleDescription {
    var description: RuleDescription { get }
    var consoleDescription: String { get }
    
    var isOptInRule: Bool { get }
    var isCorrectableRule: Bool { get }
    var isConfiguredRule: Bool { get }
    var isAnalyzerRule: Bool { get }
}

extension ConsoleDescription {
    var values: [String] {
        return [
            description.identifier,
            isOptInRule ? "yes" : "no",
            isCorrectableRule ? "yes" : "no",
            isConfiguredRule ? "yes" : "no",
            description.kind.rawValue,
            isAnalyzerRule ? "yes" : "no",
            truncated(consoleDescription)
        ]
    }
    
    private func truncated(_ string: String) -> String {
        let stringWithNoNewlines = string.replacingOccurrences(of: "\n", with: "\\n")
        let minWidth = "configuration".count - "...".count
        let configurationStartColumn = 112
        let truncatedEndIndex = stringWithNoNewlines.index(
            stringWithNoNewlines.startIndex,
            offsetBy: max(minWidth, Terminal.currentWidth() - configurationStartColumn),
            limitedBy: stringWithNoNewlines.endIndex
        )
        if let truncatedEndIndex = truncatedEndIndex {
            return stringWithNoNewlines[..<truncatedEndIndex] + "..."
        }
        return stringWithNoNewlines
    }
}

struct RuleConsoleDescription: ConsoleDescription {
    let rule: Rule
    var configuredRule: Rule?
    var customRuleConfigurations: [RegexConfiguration]? = nil
    
    init(rule: Rule, ruleID: String, configuration: Configuration) {
        self.rule = rule
        
        configuredRule = configuration.rules.first { rule in
            return type(of: rule).description.identifier == ruleID
        }
        
        if let customRules = configuredRule as? CustomRules {
            customRuleConfigurations = customRules.configuration.customRuleConfigurations
        }
    }

    var description: RuleDescription {
        return type(of: rule).description
    }
    
    var consoleDescription: String {
        return (configuredRule ?? rule).configurationDescription
    }

    var isOptInRule: Bool {
        return rule is OptInRule
    }

    var isCorrectableRule: Bool {
        return rule is CorrectableRule
    }

    var isConfiguredRule: Bool {
        return configuredRule != nil
    }

    var isAnalyzerRule: Bool {
        return rule is AnalyzerRule
    }
}

extension RegexConfiguration: ConsoleDescription {
    var isOptInRule: Bool {
        return false
    }

    var isCorrectableRule: Bool {
        return false
    }

    var isConfiguredRule: Bool {
        return true
    }

    var isAnalyzerRule: Bool {
        return false
    }
}

extension TextTable {
    static let columns = [
        TextTableColumn(header: "identifier"),
        TextTableColumn(header: "opt-in"),
        TextTableColumn(header: "correctable"),
        TextTableColumn(header: "enabled in your config"),
        TextTableColumn(header: "kind"),
        TextTableColumn(header: "analyzer"),
        TextTableColumn(header: "configuration")
    ]

    init(ruleList: RuleList, configuration: Configuration) {
        self.init(columns: TextTable.columns)
        var ruleConsoleDescriptions = [ConsoleDescription]()
            
        for (ruleID, ruleType) in ruleList.list {
            let ruleConsoleDescription = RuleConsoleDescription(rule: ruleType.init(), ruleID: ruleID, configuration: configuration)
            
            if let customRuleConfigurations = ruleConsoleDescription.customRuleConfigurations {
                ruleConsoleDescriptions.append(contentsOf: customRuleConfigurations)
            } else {
                ruleConsoleDescriptions.append(ruleConsoleDescription)
            }
        }

        for ruleConsoleDescription in ruleConsoleDescriptions.sorted(by: { $0.description.identifier < $1.description.identifier }) {
            addRow(values: ruleConsoleDescription.values)
        }
    }
}

struct Terminal {
    static func currentWidth() -> Int {
        var size = winsize()
#if os(Linux)
        _ = ioctl(CInt(STDOUT_FILENO), UInt(TIOCGWINSZ), &size)
#else
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
#endif
        return Int(size.ws_col)
    }
}
