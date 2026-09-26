import 'dart:io';

import 'package:api/api.dart';
import 'package:api/routes/app_routes.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// `openapi.yaml` and the route table describe the same API.
void main() {
  test('every route is described, and nothing else is', () {
    final YamlMap spec =
        loadYaml(File('openapi.yaml').readAsStringSync()) as YamlMap;
    final Set<String> described = <String>{
      for (final MapEntry<dynamic, dynamic> path
          in (spec['paths'] as YamlMap).entries)
        for (final dynamic method in (path.value as YamlMap).keys)
          '${'$method'.toUpperCase()} ${_openApiPath('${path.key}')}',
    };
    final Set<String> served = <String>{
      for (final ApiRoute r in appRoutes(
        const AppContext(
          internalCaller: 'internal@example.iam.gserviceaccount.com',
        ),
      ))
        '${r.method} ${r.path}',
    };
    expect(
      described.difference(served),
      isEmpty,
      reason: 'described, not served',
    );
    expect(
      served.difference(described),
      isEmpty,
      reason: 'served, not described',
    );
  });

  test('public routes say so, and only they do', () {
    final YamlMap paths =
        (loadYaml(File('openapi.yaml').readAsStringSync()) as YamlMap)['paths']
            as YamlMap;
    for (final ApiRoute r in appRoutes(
      const AppContext(
        internalCaller: 'internal@example.iam.gserviceaccount.com',
      ),
    )) {
      final YamlMap op =
          (paths[r.path.replaceAllMapped(
                    RegExp('<([^>]+)>'),
                    (Match m) => '{${m[1]}}',
                  )]
                  as YamlMap)[r.method.toLowerCase()]
              as YamlMap;
      final bool open = (op['security'] as YamlList?)?.isEmpty ?? false;
      expect(
        open,
        r.access is PublicApiAccess,
        reason: '${r.method} ${r.path}',
      );
    }
  });
}

/// `{id}` in OpenAPI is `<id>` in the route table.
String _openApiPath(String p) =>
    p.replaceAllMapped(RegExp(r'\{([^}]+)\}'), (Match m) => '<${m[1]}>');
