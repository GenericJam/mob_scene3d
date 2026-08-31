package com.example.s3d_spike

// Scene3dFilament — Filament embedding spike (bead mob_scene3d-b9g).
//
// Hosts a Filament-rendered SurfaceView inside a Mob screen through the
// tier-2 native-view seam (MobNativeViewRegistry). Uses filament-utils'
// ModelViewer for surface/UiHelper plumbing, loads a .glb via gltfio,
// adds an explicit directional light, and spins the model from a
// Choreographer frame callback (all Filament calls stay on the main
// thread — the thread that created the Engine).

import android.content.Context
import android.view.Choreographer
import android.view.SurfaceView
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.google.android.filament.EntityManager
import com.google.android.filament.LightManager
import com.google.android.filament.Skybox
import com.google.android.filament.utils.ModelViewer
import com.google.android.filament.utils.Utils
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Registered from MainActivity.onCreate, before setContent. */
object Scene3dFilamentPlugin {
    fun register() {
        MobNativeViewRegistry.register("S3dSpike_Scene3dComponent") { props, send ->
            Scene3dFilamentComposable(props, send)
        }
    }
}

@Composable
private fun Scene3dFilamentComposable(
    props: Map<String, Any?>,
    send: MobNativeSend,
) {
    val assetPath = props["asset_path"] as? String ?: return
    val w = (props["width"] as? Number)?.toFloat() ?: 340f
    val h = (props["height"] as? Number)?.toFloat() ?: 420f
    // clipToBounds: without it a surface draws past its declared bounds and
    // stomps siblings (see MobGpuView's identical treatment).
    Box(modifier = Modifier.size(w.dp, h.dp).clipToBounds()) {
        AndroidView(
            factory = { ctx ->
                FilamentGlbView(ctx, assetPath) { frames ->
                    ctx.mainExecutor.execute { send("ready", mapOf("frames" to frames)) }
                }
            },
        )
    }
}

class FilamentGlbView(
    context: Context,
    assetPath: String,
    private val onReady: (Int) -> Unit,
) : SurfaceView(context),
    Choreographer.FrameCallback {
    companion object {
        // Loads libfilament-jni, libgltfio-jni, libfilament-utils-jni.
        init {
            Utils.init()
        }
    }

    private val choreographer = Choreographer.getInstance()
    private val modelViewer = ModelViewer(surfaceView = this)
    private val baseTransform = FloatArray(16)
    private var startNanos = 0L
    private var frameCount = 0

    init {
        val engine = modelViewer.engine

        // Solid dark skybox: the surface is visibly alive even with no model.
        modelViewer.scene.skybox =
            Skybox.Builder().color(0.035f, 0.04f, 0.07f, 1.0f).build(engine)

        // ModelViewer adds its own default sunlight; remove it so the
        // spike's explicit directional light is the only one.
        modelViewer.scene.removeEntity(modelViewer.light)

        val light = EntityManager.get().create()
        LightManager
            .Builder(LightManager.Type.DIRECTIONAL)
            .color(1.0f, 0.98f, 0.92f)
            .intensity(110_000.0f)
            .direction(0.5f, -1.0f, -0.6f)
            .castShadows(true)
            .build(engine, light)
        modelViewer.scene.addEntity(light)

        val bytes = File(assetPath).readBytes()
        val buffer = ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder())
        buffer.put(bytes)
        buffer.rewind()
        modelViewer.loadModelGlb(buffer)
        modelViewer.transformToUnitCube()

        val tm = engine.transformManager
        modelViewer.asset?.let { tm.getTransform(tm.getInstance(it.root), baseTransform) }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        choreographer.postFrameCallback(this)
    }

    override fun onDetachedFromWindow() {
        choreographer.removeFrameCallback(this)
        super.onDetachedFromWindow()
    }

    override fun doFrame(frameTimeNanos: Long) {
        choreographer.postFrameCallback(this)
        if (startNanos == 0L) startNanos = frameTimeNanos
        val angle = ((frameTimeNanos - startNanos) / 1_000_000_000.0f) * 45f // 45 deg/s
        modelViewer.asset?.let { asset ->
            val tm = modelViewer.engine.transformManager
            val spin = FloatArray(16)
            android.opengl.Matrix.setRotateM(spin, 0, angle, 0f, 1f, 0f)
            val out = FloatArray(16)
            // base * spin: rotate the model in its own (origin-centered)
            // space, THEN apply transformToUnitCube's scale+translate.
            // ModelViewer's camera sits at the origin and transformToUnitCube
            // moves the model to (0,0,-4) — composing spin*base instead
            // orbits the model around the camera and out of frame.
            android.opengl.Matrix.multiplyMM(out, 0, baseTransform, 0, spin, 0)
            tm.setTransform(tm.getInstance(asset.root), out)
        }
        if (modelViewer.render(frameTimeNanos)) {
            frameCount++
            if (frameCount == 1) onReady(1)
        }
    }
}
