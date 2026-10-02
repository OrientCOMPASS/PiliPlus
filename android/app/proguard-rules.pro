-dontwarn javax.annotation.Nullable
-dontwarn org.conscrypt.Conscrypt
-dontwarn org.conscrypt.OpenSSLProvider

# ---- libvlc (local media module) -------------------------------------------
# Defensive keep rules in case minification is ever re-enabled: libvlcjni
# resolves these classes/members by name through JNI (FindClass in
# JNI_OnLoad, GetMethodID/GetFieldID for events, dialogs, media lists...).
-keep class org.videolan.libvlc.** { *; }
-keep class org.videolan.BuildConfig { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}