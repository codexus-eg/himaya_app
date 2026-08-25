plugins {
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
    id("com.google.gms.google-services") version "4.4.2" apply false
}

// يفرض compileSdk 35 على كل الـ plugin modules (يصلح خطأ resource android:attr/lStar
// اللي بتسببه printing/androidx). غير مرتبط بالخريطة (دي كانت قيود مفتاح Maps).
subprojects {
    afterEvaluate {
        extensions.findByType(com.android.build.gradle.BaseExtension::class.java)?.apply {
            compileSdkVersion(35)
        }
    }
}
