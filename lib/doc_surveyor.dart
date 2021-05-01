//  Copyright 2019 Google LLC
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      https://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

// ignore_for_file: implementation_imports

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer/src/dart/element/inheritance_manager3.dart';
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:path/path.dart' as path;
import 'package:surveyor/src/analysis.dart';
import 'package:surveyor/src/driver.dart';
import 'package:surveyor/src/visitors.dart';

Future<DocStats> analyzeDocs(String packageFolder, {bool silent = true}) async {
  var pubspec = path.join(packageFolder, 'pubspec.yaml');
  if (!File(pubspec).existsSync()) {
    throw Exception('File not found: $pubspec');
  }

  var driver = Driver.forArgs([packageFolder]);
  driver.forceSkipInstall = false;
  driver.excludedPaths = ['example', 'test'];
  driver.showErrors = true;
  driver.resolveUnits = true;
  driver.silent = silent;
  var visitor = _Visitor();
  driver.visitor = visitor;

  await driver.analyze();

  return visitor.stats;
}

class DocStats {
  int publicMemberCount = 0;
  final List<SourceLocation> undocumentedMemberLocations = <SourceLocation>[];
  final Set<DocData> docData = {};
}

class DocData {
  final String elementName;
  final String comment;
  final bool isWidget;

  DocData(this.elementName, this.isWidget, this.comment);

  /// Count of comment lines, not including lines of code in the comment.
  int get lineCount => commentWithoutCode.split('\n').length;

  /// Count of comment characters, not including any code samples or `@tool`
  /// lines in the comment, after collapsing each run of whitespace to a single
  /// space.
  int get charCount => commentWithoutCode.replaceAll(RegExp(r'\s+'), ' ').length;

  /// Count of comment words, not including words in any kind of code in the
  /// comment.
  int get wordCount => commentWithoutCode.split(RegExp(r'\s+')).length;

  /// Gets the number of code lines in the comment, regardless of whether it is
  /// in a sample or not.
  int get codeLineCount => onlyCodeFromComments.split('\n').length;

  bool get hasYouTube => comment.contains('@youtube');

  bool get hasDartPadSample => comment.contains('@tool dartpad');

  bool get hasApplicationSample => comment.contains('@tool sample');

  bool get hasSnippetSample => comment.contains('@tool snippet');

  bool get hasSeeAlso => comment.contains('See also:');

  /// Includes the description text inside of an "@tool"-based sample, but not
  /// the code itself, any dartdoc tags, or doc comment markers.
  String get commentWithoutCode => comment.replaceAll(RegExp(r'([`]{3}.*?[`]{3}|\{@\w+[^}]*\}|/// ?)', dotAll: true), '');

  /// Returns only the code parts of the comment (the opposite of [commentWithoutCode]).
  String get onlyCodeFromComments {
    return comment.replaceAllMapped(RegExp(r'[`]{3}\w*[^\n]*\n(?<code>.*?)[`]{3}', dotAll: true), (Match baseMatch) {
      RegExpMatch match = baseMatch;
      return match.namedGroup('code') ?? '';
    });
  }

  /// Strips all tool blocks from output, so it does not include the description
  /// of the sample code, or doc comment markers.
  String get commentWithoutTools {
    return comment.replaceAll(RegExp(r'(\{@tool ([^}]*)\}.*?\{@end-tool\}|/// ?)', dotAll: true), '');
  }

  int get referenceCount {
    var regex = RegExp(r'\[[. \w]*\](?!\(.*\))');
    return regex.allMatches(comment).length;
  }

  int get linkCount {
    var regex = RegExp(r'\[[. \w]*\]\(.*\)');
    return regex.allMatches(comment).length;
  }

  bool get hasCodeSnippet => comment.contains(r'```');


  @override
  bool operator ==(Object other) =>
      other is DocData && other.elementName == elementName;

  @override
  int get hashCode => elementName.hashCode;
}

class SourceLocation {
  final String displayName;
  final Source source;
  final int line;
  final int column;

  SourceLocation(this.displayName, this.source, this.line, this.column);

  String get _bullet => !Platform.isWindows ? '•' : '-';

  String asString() =>
      '$displayName $_bullet ${source.fullName} $_bullet $line:$column';
}

class _Visitor extends RecursiveAstVisitor
    implements PreAnalysisCallback, AstContext {
  bool isInLibFolder;

  AnalysisContext context;

  InheritanceManager3 inheritanceManager;

  String filePath;

  LineInfo lineInfo;

  Set<Element> apiElements;

  DocStats stats = DocStats();

  _Visitor();

  bool check(Declaration node) {
    bool apiContains(Element element) {
      while (element != null) {
        if (!element.isPrivate && apiElements.contains(element)) {
          return true;
        }
        element = element.enclosingElement;
      }
      return false;
    }

    if (!apiContains(node.declaredElement)) {
      return false;
    }

    stats.publicMemberCount++;
    if (!isOverridingMember(node) && node.declaredElement is ClassElement) {
      if (stats.docData.contains(node.declaredElement.displayName)) {
        // TODO: Is it OK to skip in this case?
        // stats.docstrings[node.declaredElement.displayName]++;
      } else {
        var element = node.declaredElement;
        var isWidget = false;
        if (element is ClassElement) {
          isWidget = isWidgetType(element.thisType);
        }
        stats.docData.add(DocData(node.declaredElement.displayName, isWidget,
            node.documentationComment.tokens.join('\n')));
      }
    }

    if (node.documentationComment == null && !isOverridingMember(node)) {
      var location = lineInfo.getLocation(node.offset);
      if (location != null) {
        stats.undocumentedMemberLocations.add(SourceLocation(
            node.declaredElement.displayName,
            node.declaredElement.source,
            location.lineNumber,
            location.columnNumber));
      }
      return true;
    }
    return false;
  }

  Element getOverriddenMember(Element member) {
    if (member == null) {
      return null;
    }

    // ignore: omit_local_variable_types
    ClassElement classElement = member.thisOrAncestorOfType<ClassElement>();
    if (classElement == null) {
      return null;
    }
    var libraryUri = classElement.library.source.uri;
    return inheritanceManager.getInherited(
      classElement.thisType,
      Name(libraryUri, member.name),
    );
  }

  bool isOverridingMember(Declaration node) =>
      getOverriddenMember(node.declaredElement) != null;

  @override
  void preAnalysis(SurveyorContext context,
      {bool subDir, DriverCommands commandCallback}) {
    inheritanceManager = InheritanceManager3();
  }

  @override
  void setFilePath(String filePath) {
    this.filePath = filePath;
  }

  @override
  void setLineInfo(LineInfo lineInfo) {
    this.lineInfo = lineInfo;
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    if (!isInLibFolder) return;

    if (isPrivate(node.name)) return;

    check(node);

    // Check methods
    var getters = <String, MethodDeclaration>{};
    var setters = <MethodDeclaration>[];

    // Non-getters/setters.
    var methods = <MethodDeclaration>[];

    // Identify getter/setter pairs.
    for (var member in node.members) {
      if (member is MethodDeclaration && !isPrivate(member.name)) {
        if (member.isGetter) {
          getters[member.name.name] = member;
        } else if (member.isSetter) {
          setters.add(member);
        } else {
          methods.add(member);
        }
      }
    }

    // Check all getters, and collect offenders along the way.
    var missingDocs = <MethodDeclaration>{};
    for (var getter in getters.values) {
      if (check(getter)) {
        missingDocs.add(getter);
      }
    }

    // But only setters whose getter is missing a doc.
    for (var setter in setters) {
      var getter = getters[setter.name.name];
      if (getter == null) {
        var libraryUri = node.declaredElement.library.source.uri;
        // Look for an inherited getter.
        var getter = inheritanceManager.getMember(
          node.declaredElement.thisType,
          Name(libraryUri, setter.name.name),
        );
        if (getter is PropertyAccessorElement) {
          if (getter.documentationComment != null) {
            continue;
          }
        }
        check(setter);
      } else if (missingDocs.contains(getter)) {
        check(setter);
      }
    }

    // Check remaining methods.
    methods.forEach(check);
  }

  @override
  void visitClassTypeAlias(ClassTypeAlias node) {
    if (!isInLibFolder) return;

    if (!isPrivate(node.name)) {
      check(node);
    }
  }

  @override
  void visitCompilationUnit(CompilationUnit node) {
    // Clear cached API elements.
    apiElements = <Element>{};

    var package = getPackage(node);
    // Ignore this compilation unit if it's not in the lib/ folder.
    isInLibFolder = isInLibDir(node, package);
    if (!isInLibFolder) return;

    var library = node.declaredElement.library;
    var namespaceBuilder = NamespaceBuilder();
    var exports = namespaceBuilder.createExportNamespaceForLibrary(library);
    var public = namespaceBuilder.createPublicNamespaceForLibrary(library);
    apiElements.addAll(exports.definedNames.values);
    apiElements.addAll(public.definedNames.values);

    var getters = <String, FunctionDeclaration>{};
    var setters = <FunctionDeclaration>[];

    // Check functions.

    // Non-getters/setters.
    var functions = <FunctionDeclaration>[];

    // Identify getter/setter pairs.
    for (var member in node.declarations) {
      if (member is FunctionDeclaration) {
        var name = member.name;
        if (!isPrivate(name) && name.name != 'main') {
          if (member.isGetter) {
            getters[member.name.name] = member;
          } else if (member.isSetter) {
            setters.add(member);
          } else {
            functions.add(member);
          }
        }
      }
    }

    // Check all getters, and collect offenders along the way.
    var missingDocs = <FunctionDeclaration>{};
    for (var getter in getters.values) {
      if (check(getter)) {
        missingDocs.add(getter);
      }
    }

    // But only setters whose getter is missing a doc.
    for (var setter in setters) {
      var getter = getters[setter.name.name];
      if (getter != null && missingDocs.contains(getter)) {
        check(setter);
      }
    }

    // Check remaining functions.
    functions.forEach(check);

    super.visitCompilationUnit(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    if (!isInLibFolder) return;

    if (!inPrivateMember(node) && !isPrivate(node.name)) {
      check(node);
    }
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    if (!isInLibFolder) return;

    if (!inPrivateMember(node) && !isPrivate(node.name)) {
      check(node);
    }
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    if (!isInLibFolder) return;

    if (!isPrivate(node.name)) {
      check(node);
    }
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    if (!isInLibFolder) return;

    if (node.name == null || isPrivate(node.name)) {
      return;
    }

    check(node);

    // Check methods

    var getters = <String, MethodDeclaration>{};
    var setters = <MethodDeclaration>[];

    // Non-getters/setters.
    var methods = <MethodDeclaration>[];

    // Identify getter/setter pairs.
    for (var member in node.members) {
      if (member is MethodDeclaration && !isPrivate(member.name)) {
        if (member.isGetter) {
          getters[member.name.name] = member;
        } else if (member.isSetter) {
          setters.add(member);
        } else {
          methods.add(member);
        }
      }
    }

    // Check all getters, and collect offenders along the way.
    var missingDocs = <MethodDeclaration>{};
    for (var getter in getters.values) {
      if (check(getter)) {
        missingDocs.add(getter);
      }
    }

    // But only setters whose getter is missing a doc.
    for (var setter in setters) {
      var getter = getters[setter.name.name];
      if (getter != null && missingDocs.contains(getter)) {
        check(setter);
      }
    }

    // Check remaining methods.
    methods.forEach(check);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    if (!isInLibFolder) return;

    if (!inPrivateMember(node)) {
      for (var field in node.fields.variables) {
        if (!isPrivate(field.name)) {
          check(field);
        }
      }
    }
  }

  @override
  void visitFunctionTypeAlias(FunctionTypeAlias node) {
    if (!isInLibFolder) return;

    if (!isPrivate(node.name)) {
      check(node);
    }
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    if (!isInLibFolder) return;

    for (var decl in node.variables.variables) {
      if (!isPrivate(decl.name)) {
        check(decl);
      }
    }
  }
}
