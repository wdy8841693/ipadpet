package com.dywu.whalepet

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Flutter 宿主 Activity。
 *
 * 这里只做三件事：注册原生能力桥、把权限结果转给它、退后台时停掉麦克风。
 * 业务逻辑全在 Dart 侧（`lib/core` + `lib/ui/mobile_scene`）。
 */
class MainActivity : FlutterActivity() {
    private var bridge: WhalePetBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = WhalePetBridge(this, flutterEngine.dartExecutor.binaryMessenger)
            .also { it.register() }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        bridge?.onPermissionResult(requestCode, grantResults)
    }

    override fun onPause() {
        bridge?.onActivityPause()
        super.onPause()
    }

    override fun onDestroy() {
        bridge?.dispose()
        bridge = null
        super.onDestroy()
    }
}
