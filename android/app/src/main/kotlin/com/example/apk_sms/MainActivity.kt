package com.example.apk_sms

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private data class Sms(val phone: String, val message: String, val result: MethodChannel.Result)
    private var awaitingPermission: Sms? = null
    private val permissions = arrayOf(Manifest.permission.READ_PHONE_STATE, Manifest.permission.SEND_SMS)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "school/airtel")
            .setMethodCallHandler { call, result ->
                if (call.method != "send") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val phone = call.argument<String>("phone")
                val message = call.argument<String>("message")
                if (phone == null || message.isNullOrBlank() || awaitingPermission != null) {
                    result.success("airtel_failed")
                    return@setMethodCallHandler
                }
                val sms = Sms(phone, message, result)
                val missing = permissions.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
                if (missing.isEmpty()) {
                    submit(sms)
                } else {
                    awaitingPermission = sms
                    requestPermissions(missing.toTypedArray(), 20)
                }
            }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 20) return
        val sms = awaitingPermission ?: return
        awaitingPermission = null
        if (this.permissions.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }) {
            submit(sms)
        } else {
            sms.result.success("airtel_permission")
        }
    }

    @Suppress("DEPRECATION")
    private fun submit(sms: Sms) {
        val status = try {
            val telephony = getSystemService(TelephonyManager::class.java)
            val subscription = getSystemService(SubscriptionManager::class.java)
                ?.activeSubscriptionInfoList.orEmpty().firstOrNull {
                    it.carrierName.toString().contains("airtel", ignoreCase = true) ||
                        telephony?.createForSubscriptionId(it.subscriptionId)?.simOperator == "63002"
                }
            if (subscription == null) {
                "airtel_no_sim"
            } else {
                val manager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    getSystemService(SmsManager::class.java).createForSubscriptionId(subscription.subscriptionId)
                } else {
                    SmsManager.getSmsManagerForSubscriptionId(subscription.subscriptionId)
                }
                val parts = manager.divideMessage(sms.message)
                if (parts.size == 1) {
                    manager.sendTextMessage(sms.phone, null, sms.message, null, null)
                } else {
                    manager.sendMultipartTextMessage(sms.phone, null, parts, null, null)
                }
                "airtel_submitted"
            }
        } catch (_: SecurityException) {
            "airtel_permission"
        } catch (_: RuntimeException) {
            "airtel_failed"
        }
        sms.result.success(status)
    }
}
