/// Distance and calorie estimates. Calories are an ESTIMATE and labelled as such
/// in the UI: walking energy cost ≈ 0.78 kcal per kg of body weight per km
/// (≈ 0.57 kcal/lb/mile at a moderate pace).
library;

const int defaultStrideCm = 75;
const double defaultWeightKg = 70;

/// Rough default stride from height (0.415 × height), clamped to sane values.
int strideFromHeightCm(double heightCm) => (heightCm * 0.415).round().clamp(40, 120);

double distanceKm(int steps, int strideCm) => steps * strideCm / 100000.0;

double estimatedKcal(int steps, int strideCm, double weightKg) =>
    0.78 * weightKg * distanceKm(steps, strideCm);

double kmToMiles(double km) => km * 0.621371;
