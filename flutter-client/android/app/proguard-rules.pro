# Flutter's engine and the Play Core library reach these by reflection, so the
# shrinker cannot see the references and would otherwise strip them. The
# symptom is a release build that works until it opens the store or an update
# prompt, then dies with a ClassNotFoundException — which is exactly the kind
# of thing that only shows up after upload.
-keep class io.flutter.** { *; }
-keep class com.google.android.play.core.** { *; }
-dontwarn com.google.android.play.core.**

# in_app_purchase talks to Play Billing through its own generated classes.
-keep class com.android.billingclient.** { *; }
-dontwarn com.android.billingclient.**
