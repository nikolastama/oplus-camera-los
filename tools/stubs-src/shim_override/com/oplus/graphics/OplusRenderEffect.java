package com.oplus.graphics;

import android.graphics.RenderEffect;
import android.graphics.Shader;

/** LineageOS port: stock HWUI has no gradient blur, so fall back to a uniform blur. */
public final class OplusRenderEffect {
    private OplusRenderEffect() {
    }

    public static RenderEffect createGradientBlurEffect(float startRadius, float endRadius,
            boolean isVertical, float speed) {
        return createGradientBlurEffect(startRadius, endRadius, isVertical, speed, 0, 0, 0);
    }

    public static RenderEffect createGradientBlurEffect(float startRadius, float endRadius,
            boolean isVertical, float speed, int blendMode, int blendC, int mixC) {
        return createGradientBlurEffect(startRadius, endRadius, isVertical, speed, blendMode,
                blendC, mixC, null);
    }

    public static RenderEffect createGradientBlurEffect(float startRadius, float endRadius,
            boolean isVertical, float speed, int blendMode, int blendC, int mixC,
            RenderEffect inputEffect) {
        float r = Math.max(0.01f, (Math.max(0f, startRadius) + Math.max(0f, endRadius)) / 2f);
        return inputEffect == null
                ? RenderEffect.createBlurEffect(r, r, Shader.TileMode.CLAMP)
                : RenderEffect.createBlurEffect(r, r, inputEffect, Shader.TileMode.CLAMP);
    }
}
