//
//  ValidDocsRule.swift
//  SwiftLint
//
//  Created by JP Simard on 2015-11-21.
//  Copyright © 2015 Realm. All rights reserved.
//

import SourceKittenFramework
import SwiftXPC

extension File {
    private func invalidDocOffsets(dictionary: XPCDictionary) -> [Int] {
        let substructure = (dictionary["key.substructure"] as? XPCArray)?
            .flatMap { $0 as? XPCDictionary } ?? []
        let substructureOffsets = substructure.flatMap(invalidDocOffsets)
        guard let kind = (dictionary["key.kind"] as? String).flatMap(SwiftDeclarationKind.init),
            offset = dictionary["key.offset"] as? Int64,
            bodyOffset = dictionary["key.bodyoffset"] as? Int64,
            comment = getDocumentationCommentBody(dictionary, syntaxMap: syntaxMap)
            where kind != .VarParameter && !comment.containsString(":nodoc:") else {
                return substructureOffsets
        }
        let declaration = contents[Int(offset)..<Int(bodyOffset)]
        let hasViolation = missingReturnDocumentation(declaration, comment: comment) ||
            superfluousReturnDocumentation(declaration, comment: comment, kind: kind) ||
            superfluousOrMissingThrowsDocumentation(declaration, comment: comment) ||
            superfluousOrMissingParameterDocumentation(declaration, substructure: substructure,
                                                       offset: offset, bodyOffset: bodyOffset,
                                                       comment: comment)

        return substructureOffsets + (hasViolation ? [Int(offset)] : [])
    }
}

func superfluousOrMissingThrowsDocumentation(declaration: String, comment: String) -> Bool {
    return declaration.containsString(" throws ") == !comment.containsString("- throws:")
}

func delcarationReturns(declaration: String, kind: SwiftDeclarationKind) -> Bool {
    return declaration.containsString("->") || SwiftDeclarationKind.variableKinds().contains(kind)
}

func commentHasBatchedParameters(comment: String) -> Bool {
    return comment.lowercaseString.containsString("- parameters:")
}

func commentReturns(comment: String) -> Bool {
    return comment.containsString("- returns:") ||
        comment.rangeOfString("Returns")?.startIndex == comment.startIndex
}

func missingReturnDocumentation(declaration: String, comment: String) -> Bool {
    return declaration.containsString("->") && !commentReturns(comment)
}

func superfluousReturnDocumentation(declaration: String, comment: String,
                                    kind: SwiftDeclarationKind) -> Bool {
    return !delcarationReturns(declaration, kind: kind) && commentReturns(comment)
}

func superfluousOrMissingParameterDocumentation(declaration: String, substructure: [XPCDictionary],
                                                offset: Int64, bodyOffset: Int64,
                                                comment: String) -> Bool {
    // This function doesn't handle batched parameters, so skip those.
    if commentHasBatchedParameters(comment) { return false }
    let parameterNames = substructure.filter {
        ($0["key.kind"] as? String).flatMap(SwiftDeclarationKind.init) == .VarParameter
    }.filter { subDict in
        return (subDict["key.offset"] as? Int64).map({ $0 < bodyOffset }) ?? false
    }.flatMap {
        $0["key.name"] as? String
    } ?? []
    let labelsAndParams = parameterNames.map { parameter -> (label: String, parameter: String) in
        let fullRange = NSRange(location: 0, length: Int(bodyOffset - offset))
        let firstMatch = regex("([^,\\s(]+)\\s+\(parameter)\\s*:")
            .firstMatchInString(declaration, options: [], range: fullRange)
        if let match = firstMatch {
            let label = (declaration as NSString).substringWithRange(match.rangeAtIndex(1))
            return (label, parameter)
        }
        return (parameter, parameter)
    }
    let commentRange = NSRange(location: 0, length: comment.utf16.count)
    let commentParameterMatches = regex("- parameter (.+):")
        .matchesInString(comment, options: [], range: commentRange)
    let commentParameters = commentParameterMatches.map { match in
        return (comment as NSString).substringWithRange(match.rangeAtIndex(1))
    }
    if commentParameters.count != labelsAndParams.count {
        return true
    }
    return !zip(commentParameters, labelsAndParams).filter {
        ![$1.label, $1.parameter].contains($0)
    }.isEmpty
}

public struct ValidDocsRule: Rule {
    public static let description = RuleDescription(
        identifier: "valid_docs",
        name: "Valid Docs",
        description: "Documented declarations should be valid.",
        nonTriggeringExamples: [
            "/// docs\npublic func a() {}\n",
            "/// docs\n/// - parameter param: this is void\npublic func a(param: Void) {}\n",
            "/// docs\n/// - parameter label: this is void\npublic func a(label param: Void) {}",
            "/// docs\n/// - parameter param: this is void\npublic func a(label param: Void) {}",
            "/// docs\n/// - returns: false\npublic func no() -> Bool { return false }",
            "/// Returns false\npublic func no() -> Bool { return false }",
            "/// Returns false\nvar no: Bool { return false }",
            "/// docs\nvar no: Bool { return false }",
            "/// docs\n/// - throws: NSError\nfunc a() throws {}",
        ],
        triggeringExamples: [
            "/// docs\npublic func a(param: Void) {}\n",
            "/// docs\n/// - parameter invalid: this is void\npublic func a(param: Void) {}",
            "/// docs\n/// - parameter invalid: this is void\npublic func a(label param: Void) {}",
            "/// docs\n/// - parameter invalid: this is void\npublic func a() {}",
            "/// docs\npublic func no() -> Bool { return false }",
            "/// Returns false\npublic func a() {}",
            "/// docs\n/// - throws: NSError\nfunc a() {}",
            "/// docs\nfunc a() throws {}",
        ]
    )

    public func validateFile(file: File) -> [StyleViolation] {
        return file.invalidDocOffsets(file.structure.dictionary).map {
            StyleViolation(ruleDescription: self.dynamicType.description,
                location: Location(file: file, offset: $0))
        }
    }
}
