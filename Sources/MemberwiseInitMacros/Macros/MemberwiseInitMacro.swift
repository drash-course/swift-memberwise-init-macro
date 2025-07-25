import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros

public struct InitMacro: PeerMacro {
  public static func expansion(
    of node: SwiftSyntax.AttributeSyntax,
    providingPeersOf declaration: some SwiftSyntax.DeclSyntaxProtocol,
    in context: some SwiftSyntaxMacros.MacroExpansionContext
  ) throws -> [SwiftSyntax.DeclSyntax] {
    return []
  }
}

public struct MemberwiseInitMacro: MemberMacro {
  public static func expansion<D, C>(
    of node: AttributeSyntax,
    providingMembersOf decl: D,
    in context: C
  ) throws -> [SwiftSyntax.DeclSyntax]
  where D: DeclGroupSyntax, C: MacroExpansionContext {
    guard [SwiftSyntax.SyntaxKind.classDecl, .structDecl, .actorDecl].contains(decl.kind) else {
      throw MacroExpansionErrorMessage(
        """
        @MemberwiseInit can only be attached to a struct, class, or actor; \
        not to \(decl.descriptiveDeclKind(withArticle: true)).
        """
      )
    }

    deprecationDiagnostics(node: node, declaration: decl)
      .forEach(context.diagnose)

    let configuredAccessLevel: AccessLevelModifier? = extractConfiguredAccessLevel(from: node)
    let optionalsDefaultNil: Bool? =
      extractLabeledBoolArgument("_optionalsDefaultNil", from: node)
    let deunderscoreParameters: Bool =
      extractLabeledBoolArgument("_deunderscoreParameters", from: node) ?? false

    let accessLevel = configuredAccessLevel ?? .internal
    let (properties, diagnostics) = try collectMemberPropertiesAndDiagnostics(
      from: decl.memberBlock.members,
      targetAccessLevel: accessLevel
    )
    diagnostics.forEach { context.diagnose($0) }

    var memberwiseInitDecl = MemberwiseInitFormatter.formatInitializer(
      properties: properties,
      accessLevel: accessLevel,
      deunderscoreParameters: deunderscoreParameters,
      optionalsDefaultNil: optionalsDefaultNil
    )

    if let classDecl = decl.as(ClassDeclSyntax.self),
       let superclass = classDecl.inheritanceClause?.inheritedTypes.first,
       superclass.type.trimmedDescription.hasSuffix("ViewController")
    {
      // the superclass is a viewcontroller, we need to add a call to the designated initializer
      let superInitStmt: StmtSyntax = "\n    super.init(nibName: nil, bundle: nil)"
      memberwiseInitDecl.body?.statements.append(
        CodeBlockItemSyntax(item: .stmt(superInitStmt))
      )

      // we also need to add the required initializer
      let requiredInitDecl: DeclSyntax = """
          @available(*, unavailable)
          required init?(coder: NSCoder) {
              fatalError("init(coder:) has not been implemented")
          }
          """

      return [DeclSyntax(memberwiseInitDecl), requiredInitDecl]
    }

    return [DeclSyntax(memberwiseInitDecl)]
  }

  static func extractConfiguredAccessLevel(
    from node: AttributeSyntax
  ) -> AccessLevelModifier? {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self)
    else { return nil }

    // NB: Search for the first argument whose name matches an access level name
    for labeledExprSyntax in arguments {
      if let identifier = labeledExprSyntax.expression.as(MemberAccessExprSyntax.self)?.declName,
        let accessLevel = AccessLevelModifier(rawValue: identifier.baseName.trimmedDescription)
      {
        return accessLevel
      }
    }

    return nil
  }

  static func extractLabeledBoolArgument(
    _ label: String,
    from node: AttributeSyntax
  ) -> Bool? {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self)
    else { return nil }

    let argument = arguments.filter { labeledExprSyntax in
      labeledExprSyntax.label?.text == label
    }.first

    guard let argument else { return nil }
    return argument.expression.as(BooleanLiteralExprSyntax.self)?.literal.text == "true"
  }

  private static func collectMemberPropertiesAndDiagnostics(
    from memberBlockItemList: MemberBlockItemListSyntax,
    targetAccessLevel: AccessLevelModifier
  ) throws -> ([MemberProperty], [Diagnostic]) {
    let (variables, variableDiagnostics) = collectMemberVariables(
      from: memberBlockItemList,
      targetAccessLevel: targetAccessLevel
    )

    let bindings = collectPropertyBindings(variables: variables)
    let bindingDiagnostics = customInitLabelDiagnosticsFor(bindings: bindings)

    var (properties, memberDiagnostics) = collectMemberProperties(bindings: bindings)
    memberDiagnostics += customInitLabelDiagnosticsFor(properties: properties)

    return (properties, variableDiagnostics + bindingDiagnostics + memberDiagnostics)
  }

  private static func collectMemberVariables(
    from memberBlockItemList: MemberBlockItemListSyntax,
    targetAccessLevel: AccessLevelModifier
  ) -> ([MemberVariable], [Diagnostic]) {
    memberBlockItemList
      .reduce(
        into: (
          variables: [MemberVariable](),
          diagnostics: [Diagnostic]()
        )
      ) { acc, member in
        guard
          let variable = member.decl.as(VariableDeclSyntax.self),
          variable.attributes.isEmpty || variable.hasCustomConfigurationAttribute,
          !variable.isComputedProperty
        else { return }

        if let diagnostics = diagnoseMultipleConfigurations(variable: variable) {
          acc.diagnostics += diagnostics
          return
        }

        let customSettings = extractVariableCustomSettings(from: variable)
        if let customSettings, customSettings.ignore {
          return
        }

        let diagnostics = diagnoseVariableDecl(
          customSettings: customSettings,
          variable: variable,
          targetAccessLevel: targetAccessLevel
        )
        guard diagnostics.isEmpty else {
          acc.diagnostics += diagnostics
          return
        }

        guard variable.modifiersExclude([.static, .lazy]) else { return }

        acc.variables.append(
          MemberVariable(
            customSettings: customSettings,
            syntax: variable
          )
        )
      }
  }

  private static func collectPropertyBindings(variables: [MemberVariable]) -> [PropertyBinding] {
    variables.flatMap { variable -> [PropertyBinding] in
      variable.bindings
        .reversed()
        .reduce(
          into: (
            bindings: [PropertyBinding](),
            typeFromTrailingBinding: TypeSyntax?.none
          )
        ) { acc, binding in
          acc.bindings.append(
            PropertyBinding(
              typeFromTrailingBinding: acc.typeFromTrailingBinding,
              syntax: binding,
              variable: variable
            )
          )
          acc.typeFromTrailingBinding =
            binding.typeAnnotation?.type ?? acc.typeFromTrailingBinding
        }
        .bindings
        .reversed()
    }
  }

  private static func collectMemberProperties(
    bindings: [PropertyBinding]
  ) -> (
    members: [MemberProperty],
    diagnostics: [Diagnostic]
  ) {
    bindings.reduce(
      into: (
        members: [MemberProperty](),
        diagnostics: [Diagnostic]()
      )
    ) { acc, propertyBinding in
      if propertyBinding.isInitializedLet {
        return
      }

      if propertyBinding.isInitializedVarWithoutType {
        acc.diagnostics.append(
          propertyBinding.diagnostic(
            MacroExpansionErrorMessage("@MemberwiseInit requires a type annotation.")
          )
        )
        return
      }
      if propertyBinding.isTuplePattern {
        acc.diagnostics.append(
          propertyBinding.diagnostic(
            MacroExpansionErrorMessage(
              """
              @MemberwiseInit does not support tuple destructuring for property declarations. \
              Use multiple declarations instead.
              """
            )
          )
        )

        return
      }

      guard
        let name = propertyBinding.name,
        let effectiveType = propertyBinding.effectiveType
      else { return }

      let newProperty = MemberProperty(
        accessLevel: propertyBinding.variable.accessLevel,
        customSettings: propertyBinding.variable.customSettings,
        initializerValue: propertyBinding.initializerValue,
        keywordToken: propertyBinding.variable.keywordToken,
        name: name,
        type: effectiveType.trimmed
      )
      acc.members.append(newProperty)
    }
  }

  static func extractVariableCustomSettings(
    from variable: VariableDeclSyntax
  ) -> VariableCustomSettings? {
    guard let customConfigurationAttribute = variable.customConfigurationAttribute else {
      return nil
    }

    let customConfiguration = variable.customConfigurationArguments

    let configuredValues =
      customConfiguration?.compactMap {
        $0.expression.as(MemberAccessExprSyntax.self)?.declName.baseName.trimmedDescription
      }

    let configuredAccessLevel =
      configuredValues?
      .compactMap(AccessLevelModifier.init(rawValue:))
      .first

    let configuredAssignee: VariableCustomSettings.Assignee? =
      (customConfigurationAttribute.isInitWrapper ? .wrapper : nil)
      ?? customConfiguration?
      .firstWhereLabel("assignee")?
      .expression
      .trimmedStringLiteral
      .map(VariableCustomSettings.Assignee.raw)

    let configuredForceEscaping =
      (customConfiguration?
        .firstWhereLabel("escaping")?
        .expression
        .as(BooleanLiteralExprSyntax.self)?
        .literal
        .text == "true")
      || configuredValues?.contains("escaping") ?? false  // Deprecated; remove in 1.0

    let configuredIgnore = configuredValues?.contains("ignore") ?? false

    let configuredDefault =
      customConfiguration?
      .firstWhereLabel("default")?
      .expression
      .trimmedDescription

    let configuredLabel =
      customConfiguration?
      .firstWhereLabel("label")?
      .expression
      .trimmedStringLiteral

    let typeExpr =
      customConfiguration?
      .firstWhereLabel("type")?
      .expression

    let typeString: String? = typeExpr.flatMap { expr -> String? in
      // For Swift 6 style with .self suffix
      if let memberAccess = expr.as(MemberAccessExprSyntax.self),
        memberAccess.declName.baseName.text == "self",
        let baseExpr = memberAccess.base
      {
        return baseExpr.trimmedDescription
      }
      // For Swift 5 style without .self suffix
      return expr.trimmedDescription
    }

    // Create TypeSyntax from the string
    let configuredTypeSyntax =
      typeString.map(TypeSyntax.init(stringLiteral:))

    return VariableCustomSettings(
      accessLevel: configuredAccessLevel,
      assignee: configuredAssignee,
      defaultValue: configuredDefault,
      forceEscaping: configuredForceEscaping,
      ignore: configuredIgnore,
      label: configuredLabel,
      type: configuredTypeSyntax,
      _syntaxNode: customConfigurationAttribute
    )
  }

  static func defaultOptionalsDefaultNil(
    for bindingKeyword: TokenKind,
    initAccessLevel: AccessLevelModifier
  ) -> Bool {
    guard bindingKeyword == .keyword(.var) else { return false }
    return switch initAccessLevel {
    case .private, .fileprivate, .internal, .package, .public:
      true
    case .open:
      false
    }
  }
}
