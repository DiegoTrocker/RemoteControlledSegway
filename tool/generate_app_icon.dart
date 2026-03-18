import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image/image.dart' as img;

/// Helper app that renders the SVG asset offscreen and writes PNG files.
///
/// Run with:
///   flutter run -d windows --target=tool/generate_app_icon.dart --release
///
/// This generates the launcher icons under android/app/src/main/res/mipmap-*/ic_launcher.png
class _IconGeneratorApp extends StatefulWidget {
  const _IconGeneratorApp({super.key});

  @override
  State<_IconGeneratorApp> createState() => _IconGeneratorAppState();
}

class _IconGeneratorAppState extends State<_IconGeneratorApp> {
  final GlobalKey _repaintKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _generateIcons());
  }

  Future<void> _generateIcons() async {
    // Capture once at a large size, then downscale for each density.
    final boundary = _repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) {
      stderr.writeln('Could not find render object for icon capture.');
      exit(1);
    }

    final image = await boundary.toImage(pixelRatio: 1.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) {
      stderr.writeln('Failed to capture PNG bytes.');
      exit(1);
    }

    final original = img.decodePng(bytes.buffer.asUint8List());
    if (original == null) {
      stderr.writeln('Failed to decode captured PNG.');
      exit(1);
    }

    final androidDensities = <String, int>{
      'mipmap-mdpi': 48,
      'mipmap-hdpi': 72,
      'mipmap-xhdpi': 96,
      'mipmap-xxhdpi': 144,
      'mipmap-xxxhdpi': 192,
    };

    for (final entry in androidDensities.entries) {
      await _writeIcon(original, entry.value, 'android/app/src/main/res/${entry.key}/ic_launcher.png');
    }

    final iosIcons = <String, int>{
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png': 20,
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@2x.png': 40,
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@3x.png': 60,
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@1x.png': 29,
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@2x.png': 58,
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@3x.png': 87,
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@1x.png': 40,
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@2x.png': 80,
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@3x.png': 120,
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@2x.png': 120,
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png': 180,
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@1x.png': 76,
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@2x.png': 152,
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-83.5x83.5@2x.png': 167,
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png': 1024,
    };

    for (final entry in iosIcons.entries) {
      await _writeIcon(original, entry.value, entry.key);
    }

    stdout.writeln('Launcher icons generated successfully.');
    exit(0);
  }

  Future<void> _writeIcon(img.Image source, int size, String outputPath) async {
    final outputFile = File(outputPath);
    outputFile.parent.createSync(recursive: true);

    final resized = img.copyResize(source, width: size, height: size, interpolation: img.Interpolation.average);
    final png = img.encodePng(resized);

    await outputFile.writeAsBytes(png);
    stdout.writeln('Wrote $outputPath (${size}x$size)');
  }

  @override
  Widget build(BuildContext context) {
    // Use a fixed size for the repaint boundary so each capture is square.
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: RepaintBoundary(
            key: _repaintKey,
            child: SizedBox(
              width: 1024,
              height: 1024,
              child: SvgPicture.asset(
                'data/img/segway_icon.svg',
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _IconGeneratorApp());
}
