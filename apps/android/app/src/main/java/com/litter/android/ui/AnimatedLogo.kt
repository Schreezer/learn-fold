package com.litter.android.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.sigkitten.litter.android.R
import kotlin.math.sin

/** Compact Learnfold mark used in the app chrome. */
@Composable
fun AnimatedLogo(size: Dp = 44.dp) {
    val frameTime = remember { mutableLongStateOf(0L) }
    val startTime = remember { System.nanoTime() }

    LaunchedEffect(Unit) {
        while (true) {
            withFrameMillis { frameTime.longValue = it }
        }
    }

    @Suppress("UNUSED_VARIABLE")
    val currentFrame = frameTime.longValue
    val elapsed = (System.nanoTime() - startTime) / 1_000_000_000.0
    val pulse = (1.0 + sin(elapsed * 2.4) * 0.025).toFloat()
    val rise = (sin(elapsed * 1.7) * 0.8).toFloat()

    Image(
        painter = painterResource(R.drawable.brand_logo),
        contentDescription = null,
        modifier = Modifier
            .size(size)
            .graphicsLayer(
                scaleX = pulse,
                scaleY = pulse,
                translationY = rise,
            ),
    )
}
