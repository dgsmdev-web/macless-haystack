package de.dchristl.headlesshaystack

import android.os.Build
import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity (not the plain FlutterActivity this project
// used before) is required by the local_auth plugin — it shows the
// biometric/fingerprint prompt as a Fragment, which needs a
// FragmentActivity host to attach to.
class MainActivity: FlutterFragmentActivity() {

      override fun onCreate(savedInstanceState: Bundle?) {
    // Aligns the Flutter view vertically with the window.
    WindowCompat.setDecorFitsSystemWindows(getWindow(), false)

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      // Disable the Android splash screen fade out animation to avoid
      // a flicker before the similar frame is drawn in Flutter.
      splashScreen.setOnExitAnimationListener { splashScreenView -> splashScreenView.remove() }
    }

    super.onCreate(savedInstanceState)
  }
}

