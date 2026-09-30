package com.example.piliplus.vr

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.util.Log
import kotlin.math.asin
import kotlin.math.atan2

/**
 * 头部追踪：转动设备环视（对应 xl_player 的 HeadTracker / OrientationEKF）。
 *
 * 优先用**旋转矢量传感器**（`TYPE_ROTATION_VECTOR`，系统已把陀螺仪+加速度计+
 * 磁力计融合成绝对姿态），每次事件算出绝对 yaw/pitch，再取**相邻两次的差**
 * 累加到视角上 —— 因为每次增量都是两个绝对值之差，所以**不会像纯陀螺仪积分
 * 那样慢漂**（这正是 Dart 版 `VrGyroMath` 的已知限制）。
 *
 * 没有旋转矢量传感器时退回「加速度计定姿态 + 陀螺仪积分」，与 Dart 版同构。
 *
 * 坐标约定与 Dart 侧完全一致：**yaw+ = 向右看，pitch+ = 向上看**。
 * 推导：Android 设备坐标 X 向右、Y 向上、Z 垂直屏幕**指向用户**；
 * `getRotationMatrixFromVector` 给的 R 把设备坐标映到世界坐标（X 东、Y 北、Z 天）。
 * magic-window 模式下"看向"的是**背面摄像头的方向 = -Z**（手机举起来对着场景、
 * 屏幕朝着自己），所以视线向量 f = -R·(0,0,1) = -(R 的第三列)；
 * yaw = atan2(f.x, f.y)（以北为 0、向东为正 → 右转时增大），
 * pitch = asin(f.z)（抬头时增大）。
 * **用 +Z 会得到符号相反的 pitch** —— 第六轮真机反馈的"上下是反的"就是这个，
 * 而 yaw 只差一个常量 π、取相邻两次差值时自动抵消，所以当时只有俯仰翻。
 *
 * 增量不直接改视角，而是攒在 [drain] 里由 GL 线程每帧取走，
 * 避免传感器线程和渲染线程抢同一组 volatile 浮点数。
 */
internal class VrHeadTracker(private val context: Context) : SensorEventListener {
    companion object {
        private const val TAG = "VrHeadTracker"
        private const val RAD2DEG = (180.0 / Math.PI).toFloat()

        /** 静止时的角速度死区（rad/s），压住手抖与零偏 */
        private const val DEADZONE = 0.02f

        /** 单帧最大转动量，防止传感器抽风时视角瞬间飞走 */
        private const val MAX_DELTA_DEG = 8f
    }

    private var sensorManager: SensorManager? = null
    private var useRotationVector = false
    private var running = false

    private val rotationMatrix = FloatArray(9)
    private var lastAbsYaw: Float? = null
    private var lastAbsPitch: Float? = null

    private val lock = Any()
    private var pendingYaw = 0f
    private var pendingPitch = 0f

    /** 取走并清空累积的视角增量（GL 线程每帧调用） */
    fun drain(): Pair<Float, Float> = synchronized(lock) {
        val r = pendingYaw to pendingPitch
        pendingYaw = 0f
        pendingPitch = 0f
        r
    }

    fun start() {
        if (running) return
        val sm = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager ?: return
        sensorManager = sm
        val rv = sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
            ?: sm.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
        useRotationVector = rv != null
        lastAbsYaw = null
        lastAbsPitch = null
        if (rv != null) {
            // 20ms ≈ 50Hz：够跟手，又不会把主线程/渲染线程淹掉
            sm.registerListener(this, rv, 20_000)
        } else {
            val gyro = sm.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
            val accel = sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
            if (gyro == null) {
                Log.w(TAG, "no rotation-vector and no gyroscope")
                return
            }
            sm.registerListener(this, gyro, 20_000)
            if (accel != null) sm.registerListener(this, accel, 200_000)
        }
        running = true
    }

    fun stop() {
        if (!running) return
        running = false
        try {
            sensorManager?.unregisterListener(this)
        } catch (_: Throwable) {
        }
        sensorManager = null
        synchronized(lock) {
            pendingYaw = 0f
            pendingPitch = 0f
        }
    }

    // 陀螺仪退回方案的状态
    private val gravity = FloatArray(3)
    private var lastGyroNanos = 0L

    override fun onSensorChanged(event: SensorEvent) {
        if (!running) return
        when (event.sensor.type) {
            Sensor.TYPE_ROTATION_VECTOR, Sensor.TYPE_GAME_ROTATION_VECTOR -> {
                try {
                    SensorManager.getRotationMatrixFromVector(rotationMatrix, event.values)
                } catch (e: IllegalArgumentException) {
                    return // 个别机型在传感器还没 ready 时会给长度不对的 values
                }
                // R 的第三列 = **屏幕法线**(+Z, 指向用户)在世界坐标里的方向。
                // 但 magic-window 模式下"看向"的是**背面摄像头**的方向(-Z):
                // 你把手机举起来对着场景, 屏幕朝着自己。用 +Z 会让俯仰符号
                // 正好相反 —— 真机反馈"陀螺仪上下是反的"就是这个。
                // (偏航只因此差一个常量 π, 而这里用的是相邻两次的**差值**,
                //  常量自动抵消, 所以偏航一直是对的、只有俯仰翻。)
                val fx = -rotationMatrix[2]
                val fy = -rotationMatrix[5]
                val fz = -rotationMatrix[8]
                val yaw = atan2(fx, fy) * RAD2DEG
                val pitch = asin(fz.coerceIn(-1f, 1f)) * RAD2DEG
                val prevYaw = lastAbsYaw
                val prevPitch = lastAbsPitch
                lastAbsYaw = yaw
                lastAbsPitch = pitch
                if (prevYaw == null || prevPitch == null) return
                addDelta(wrap180(yaw - prevYaw), pitch - prevPitch)
            }

            Sensor.TYPE_ACCELEROMETER -> {
                // 只做低通，用来把陀螺仪的设备坐标角速度转到世界坐标
                val a = event.values
                val alpha = 0.8f
                gravity[0] = alpha * gravity[0] + (1 - alpha) * a[0]
                gravity[1] = alpha * gravity[1] + (1 - alpha) * a[1]
                gravity[2] = alpha * gravity[2] + (1 - alpha) * a[2]
            }

            Sensor.TYPE_GYROSCOPE -> {
                val now = event.timestamp
                val last = lastGyroNanos
                lastGyroNanos = now
                if (last == 0L) return
                val dt = (now - last) / 1_000_000_000f
                if (dt <= 0f || dt > 0.5f) return
                val wx = event.values[0]
                val wy = event.values[1]
                if (kotlin.math.abs(wx) < DEADZONE && kotlin.math.abs(wy) < DEADZONE) return
                // 没有旋转矢量传感器时的退回方案: 用重力判定持握姿态, 再把
                // 设备坐标的角速度映射到"偏航/俯仰"。四种姿态各自推导
                // (视角方向 = -Z, 偏航 = 绕世界竖直轴, 俯仰 = 绕视线左右的水平轴):
                //   竖屏(+y 朝上)      : dyaw = -wy, dpitch = +wx
                //   竖屏倒置(+y 朝下)  : dyaw = +wy, dpitch = -wx
                //   横屏顶左(+x 朝上)  : dyaw = -wx, dpitch = -wy
                //   横屏顶右(+x 朝下)  : dyaw = +wx, dpitch = +wy
                val g = gravity
                val (dyaw, dpitch) = if (kotlin.math.abs(g[1]) >= kotlin.math.abs(g[0])) {
                    if (g[1] >= 0) Pair(-wy, wx) else Pair(wy, -wx)
                } else {
                    if (g[0] >= 0) Pair(-wx, -wy) else Pair(wx, wy)
                }
                addDelta(dyaw * dt * RAD2DEG, dpitch * dt * RAD2DEG)
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private fun addDelta(dyaw: Float, dpitch: Float) {
        val y = clampDelta(dyaw)
        val p = clampDelta(dpitch)
        if (y == 0f && p == 0f) return
        synchronized(lock) {
            pendingYaw += y
            pendingPitch += p
        }
    }

    private fun clampDelta(v: Float) = v.coerceIn(-MAX_DELTA_DEG, MAX_DELTA_DEG)

    /** 把角度差收敛到 (-180, 180]，处理 atan2 的跳变 */
    private fun wrap180(v: Float): Float {
        var r = v % 360f
        if (r > 180f) r -= 360f
        if (r < -180f) r += 360f
        return r
    }
}
