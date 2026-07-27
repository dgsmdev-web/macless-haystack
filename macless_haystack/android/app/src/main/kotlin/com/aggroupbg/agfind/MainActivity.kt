package com.aggroupbg.agfind

import android.os.Build
import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity

// ВРЕМЕННО для теста — обычный FlutterActivity вместо FlutterFragmentActivity.
// Это отключит вход по отпечатку пальца (PIN продолжит работать), но
// позволит проверить, была ли именно эта смена причиной зависаний карты.
class MainActivity: FlutterActivity() {

      override fun onCreate(savedInstanceState: Bundle?) {
    WindowCompat.setDecorFitsSystemWindows(getWindow(), false)

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      splashScreen.setOnExitAnimationListener { splashScreenView -> splashScreenView.remove() }
    }

    super.onCreate(savedInstanceState)
  }
}
