import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/analytics_models.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/feedback.dart';
import '../util/list_export.dart';
import '../util/prefs.dart';
import '../widgets/analytics_charts.dart';
import '../widgets/ui.dart';

/// Analyses : deux modules. « Tableau de bord » = des tuiles (vues
/// enregistrées) que l'on déplace et redimensionne à la souris, avec une
/// période globale et un seul appel batch. « Explorateur » = le constructeur
/// de vues guidé (1. quoi · 2. par quoi · 3. période · 4. filtres), la
/// réponse en direct et le style. Le vocabulaire est celui d'un tableau
/// croisé, jamais celui de SQL.
///
/// Fichiers : analytics/common.dart (bus, demande, période, sélecteurs),
/// analytics/dashboard.dart, analytics/explorer.dart, analytics/builder.dart
/// (constructeur guidé), analytics/panels.dart (enregistrement, Mes vues,
/// style et couleurs conditionnelles), analytics/setup_checklist.dart.
part 'analytics/common.dart';
part 'analytics/dashboard.dart';
part 'analytics/explorer.dart';
part 'analytics/builder.dart';
part 'analytics/panels.dart';
part 'analytics/setup_checklist.dart';
