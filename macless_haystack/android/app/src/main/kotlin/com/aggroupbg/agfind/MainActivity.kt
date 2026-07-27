package com.aggroupbg.agfind

import android.os.Build
import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity (not the plain FlutterActivity this project
// used before) is required by the local_auth plugin — it shows the
// biometric/fingerprint prompt as a Fragment, which needs a
// FragmentActivity host to attach to. Confirmed via testing that this
// is NOT related to the map freeze issue — both variants froze
// identically, so this stays as FlutterFragmentActivity to keep
// fingerprint unlock working.
class MainActivity: FlutterFragmentActivity() {

      override fun onCreate(savedInstanceState: Bundle?) {
    WindowCompat.setDecorFitsSystemWindows(getWindow(), false)

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      splashScreen.setOnExitAnimationListener { splashScreenView -> splashScreenView.remove() }
    }

    super.onCreate(savedInstanceState)
  }
}
