import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import '../models/merch_order.dart';

// Match the convention used elsewhere (business_upgrade_screen.dart,
// guest_event_screen.dart, settings_screen.dart). Flip to false for live orders.
const bool kTestingMode = true;

class MerchOrderService {
  static final _fn = FirebaseFunctions.instance;

  /// Stripe step 1 — get a client secret for the total. Returns null in test
  /// mode so the caller can short-circuit and skip the Stripe SDK.
  static Future<String?> createPaymentIntent(int amountCents) async {
    if (kTestingMode) return null;
    final res = await _fn.httpsCallable('createPaymentIntent').call({
      'amount': amountCents, 'currency': 'usd',
    });
    return (res.data as Map?)?['clientSecret'] as String?;
  }

  /// Stripe step 2 — confirm with the SDK. Returns the succeeded
  /// PaymentIntent id, or `pi_test_mock_{ts}` so the server can detect test
  /// orders and skip Stripe verification + actual fulfillment.
  static Future<String> confirmPayment({
    required String? clientSecret,
    required MerchAddress billingAddress,
  }) async {
    if (kTestingMode || clientSecret == null) {
      return 'pi_test_mock_${DateTime.now().millisecondsSinceEpoch}';
    }
    final pi = await Stripe.instance.confirmPayment(
      paymentIntentClientSecret: clientSecret,
      data: PaymentMethodParams.card(
        paymentMethodData: PaymentMethodData(
          billingDetails: BillingDetails(
            name: billingAddress.name,
            address: Address(
              line1: billingAddress.line1, line2: billingAddress.line2,
              city: billingAddress.city, state: billingAddress.state,
              postalCode: billingAddress.zip, country: billingAddress.country,
            ),
          ),
        ),
      ),
    );
    if (pi.status != PaymentIntentsStatus.Succeeded) {
      throw Exception('Payment did not succeed: ${pi.status}');
    }
    return pi.id;
  }

  /// Hand off to the Cloud Function. Print files are generated server-side
  /// from the chosen theme — clients can no longer supply their own art.
  /// Returns { orderId, status, ... }.
  static Future<Map<String, dynamic>> createOrder({
    required String eventId,
    required MerchProduct productType,
    required int packSize,
    required String themeKey,
    required int themeVariant,
    required MerchAddress shippingAddress,
    required MerchShipping shippingSpeed,
    required String paymentIntentId,
  }) async {
    final res = await _fn.httpsCallable('createMerchOrder').call({
      'eventId': eventId,
      'productType': productType == MerchProduct.invitation ? 'invitation' : 'sticker',
      'packSize': packSize,
      'theme': themeKey,
      'themeVariant': themeVariant,
      'shippingAddress': shippingAddress.toMap(),
      'shippingSpeed': shippingSpeed == MerchShipping.expedited ? 'expedited' : 'standard',
      'paymentIntentId': paymentIntentId,
    });
    return Map<String, dynamic>.from(res.data as Map);
  }
}
