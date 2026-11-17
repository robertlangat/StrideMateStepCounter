import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../config/app_config.dart';

/// Initialises the Mobile Ads SDK once. Safe to call without awaiting.
class Ads {
  static bool _started = false;

  static Future<void> init() async {
    if (_started || !AppConfig.adsEnabled || !(Platform.isAndroid || Platform.isIOS)) return;
    _started = true;
    try {
      await MobileAds.instance.initialize();
    } catch (_) {
      // Ads are optional: never block or crash the app.
    }
  }
}

/// Anchored adaptive banner shown above the bottom navigation bar.
/// Ad requests carry no health or activity data.
class AdBanner extends StatefulWidget {
  const AdBanner({super.key});

  @override
  State<AdBanner> createState() => _AdBannerState();
}

class _AdBannerState extends State<AdBanner> {
  BannerAd? _ad;
  bool _loaded = false;
  int? _width;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final width = MediaQuery.of(context).size.width.truncate();
    if (width != _width) {
      _width = width;
      _load(width);
    }
  }

  Future<void> _load(int width) async {
    if (!AppConfig.adsEnabled || !(Platform.isAndroid || Platform.isIOS)) return;
    await _ad?.dispose();
    _ad = null;
    _loaded = false;
    final size = await AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width);
    if (size == null || !mounted) return;
    final ad = BannerAd(
      adUnitId: Platform.isIOS ? AppConfig.bannerAdUnitIos : AppConfig.bannerAdUnitAndroid,
      size: size,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          if (!mounted) {
            ad.dispose();
            return;
          }
          setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          if (mounted) setState(() => _ad = null);
        },
      ),
    );
    _ad = ad;
    await ad.load();
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (ad == null || !_loaded) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      bottom: false,
      child: Semantics(
        label: 'Advertisement',
        container: true,
        child: SizedBox(
          width: ad.size.width.toDouble(),
          height: ad.size.height.toDouble(),
          child: AdWidget(ad: ad),
        ),
      ),
    );
  }
}
