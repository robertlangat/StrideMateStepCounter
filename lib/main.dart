import 'dart:async';

import 'package:flutter/material.dart';

import 'ads/ad_banner.dart';

import 'app.dart';
import 'core/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Services.create();
  unawaited(Ads.init());
  runApp(const StrideMateApp());
}
