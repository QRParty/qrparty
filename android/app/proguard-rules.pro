# Stripe Push Provisioning — suppress R8 missing-class warnings and keep classes
-dontwarn com.stripe.android.pushProvisioning.**
-keep class com.stripe.android.pushProvisioning.** { *; }
