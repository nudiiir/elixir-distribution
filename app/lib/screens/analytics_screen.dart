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

/// Analytics: two modules. « Tableau de bord » = tiles (saved
/// views) moved and resized with the mouse, with a
/// global period and a single batch call. « Explorateur » = the guided
/// view builder (1. what · 2. by what · 3. period · 4. filters), the
/// live answer and the styling. The vocabulary is that of a pivot
/// table, never SQL's.
///
/// Files: analytics/common.dart (bus, request, period, selectors),
/// analytics/dashboard.dart, analytics/explorer.dart, analytics/builder.dart
/// (guided builder), analytics/panels.dart (saving, « Mes vues »,
/// style and conditional colours), analytics/setup_checklist.dart.
part 'analytics/common.dart';
part 'analytics/dashboard.dart';
part 'analytics/explorer.dart';
part 'analytics/builder.dart';
part 'analytics/panels.dart';
part 'analytics/setup_checklist.dart';
