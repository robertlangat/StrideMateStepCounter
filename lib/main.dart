import 'package:flutter/material.dart';

import 'app.dart';
import 'core/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Services.create();
  runApp(const StrideMateApp());
}
