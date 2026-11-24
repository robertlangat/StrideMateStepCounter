import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../config/app_config.dart';

/// Initialises the Mobile Ads SDK once. Safe to call without awaiting.
class Ads {
  static bool _started = false;
  static final DateTime _sessionStart = DateTime.now();
  static DateTime? _lastInterstitial;
  static InterstitialAd? _interstitial;
  static bool _loading = false;

  /// Interstitials are shown only on natural breaks (opening Recaps or
  /// Achievements), never in the first 2 minutes of a session and at most once
  /// every 4 minutes.
  static const firstShowDelay = Duration(minutes: 2);
  static const minInterval = Duration(minutes: 4);

  static bool get _supported => AppConfig.adsEnabled && (Platform.isAndroid || Platform.isIOS);

  static Future<void> init() async {
    if (_started || !_supported) return;
    _started = true;
    try {
      await MobileAds.instance.initialize();
      _loadInterstitial();
    } catch (_) {
      // Ads are optional: never block or crash the app.
    }
  }

  static void _loadInterstitial() {
    if (_loading || _interstitial != null || !_supported) return;
    _loading = true;
    InterstitialAd.load(
      adUnitId: AppConfig.interstitialAdUnit,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _loading = false;
          _interstitial = ad;
        },
        onAdFailedToLoad: (error) {
          _loading = false;
          _interstitial = null;
        },
      ),
    );
  }

  /// Shows a preloaded interstitial if the frequency cap allows. Never waits
  /// for an ad: if none is ready, the user continues straight away.
  static void maybeShowInterstitial() {
    if (!_supported) return;
    final now = DateTime.now();
    final ad = _interstitial;
    if (ad == null) {
      _loadInterstitial();
      return;
    }
    if (now.difference(_sessionStart) < firstShowDelay) return;
    if (_lastInterstitial != null && now.difference(_lastInterstitial!) < minInterval) return;
    _interstitial = null;
    _lastInterstitial = now;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _loadInterstitial();
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        ad.dispose();
        _loadInterstitial();
      },
    );
    ad.show();
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
      adUnitId: AppConfig.bannerAdUnit,
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
