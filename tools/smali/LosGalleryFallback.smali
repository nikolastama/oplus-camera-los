.class public final Lcom/oplus/camera/helper/LosGalleryFallback;
.super Ljava/lang/Object;
.source "LosGalleryFallback.java"

# LineageOS module: the OnePlus gallery is not installed, so the thumbnail opens the photo in
# whatever app handles ACTION_VIEW (e.g. Glimpse). A photo tapped right after capture is still
# the quick preview JPEG; the processed (HDR / multi-frame) image replaces it a moment later,
# and other galleries keep showing their first (quick) decode until zoomed. So a photo taken in
# the last minute whose final image is not saved yet is opened as soon as it is (max 8 s wait).
# All state is touched on the main thread only.

.field private static sHandler:Landroid/os/Handler;
.field private static sPendingAct:Landroid/app/Activity;
.field private static sPendingUri:Landroid/net/Uri;
.field private static sPendingMime:Ljava/lang/String;
.field private static final sSaved:Ljava/util/HashSet;


.method static constructor <clinit>()V
    .locals 1
    new-instance v0, Ljava/util/HashSet;
    invoke-direct {v0}, Ljava/util/HashSet;-><init>()V
    sput-object v0, Lcom/oplus/camera/helper/LosGalleryFallback;->sSaved:Ljava/util/HashSet;
    return-void
.end method

.method private static handler()Landroid/os/Handler;
    .locals 2
    sget-object v0, Lcom/oplus/camera/helper/LosGalleryFallback;->sHandler:Landroid/os/Handler;
    if-nez v0, :cond_0
    new-instance v0, Landroid/os/Handler;
    invoke-static {}, Landroid/os/Looper;->getMainLooper()Landroid/os/Looper;
    move-result-object v1
    invoke-direct {v0, v1}, Landroid/os/Handler;-><init>(Landroid/os/Looper;)V
    sput-object v0, Lcom/oplus/camera/helper/LosGalleryFallback;->sHandler:Landroid/os/Handler;
    :cond_0
    return-object v0
.end method

.method private static launch(Landroid/app/Activity;Landroid/net/Uri;Ljava/lang/String;)V
    .locals 3
    if-eqz p0, :cond_done
    if-eqz p1, :cond_done
    :try_start_0
    invoke-virtual {p0}, Landroid/app/Activity;->isFinishing()Z
    move-result v0
    if-nez v0, :cond_done
    invoke-virtual {p0}, Landroid/app/Activity;->isDestroyed()Z
    move-result v0
    if-nez v0, :cond_done
    new-instance v0, Landroid/content/Intent;
    const-string v1, "android.intent.action.VIEW"
    invoke-direct {v0, v1}, Landroid/content/Intent;-><init>(Ljava/lang/String;)V
    invoke-virtual {v0, p1, p2}, Landroid/content/Intent;->setDataAndType(Landroid/net/Uri;Ljava/lang/String;)Landroid/content/Intent;
    const/4 v1, 0x1
    invoke-virtual {v0, v1}, Landroid/content/Intent;->addFlags(I)Landroid/content/Intent;
    invoke-virtual {p0, v0}, Landroid/app/Activity;->startActivity(Landroid/content/Intent;)V
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0
    goto :cond_done
    :catch_0
    move-exception v0
    const-string v1, "GalleryHelper"
    const-string v2, "LOS gallery fallback failed"
    invoke-static {v1, v2, v0}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Throwable;)I
    :cond_done
    return-void
.end method

# main thread: p0 = uri whose final image was just saved, or null for the timeout
.method static firePending(Landroid/net/Uri;)V
    .locals 4
    if-eqz p0, :cond_check
    sget-object v0, Lcom/oplus/camera/helper/LosGalleryFallback;->sSaved:Ljava/util/HashSet;
    invoke-virtual {v0}, Ljava/util/HashSet;->size()I
    move-result v1
    const/16 v2, 0x40
    if-lt v1, v2, :cond_add
    invoke-virtual {v0}, Ljava/util/HashSet;->clear()V
    :cond_add
    invoke-virtual {p0}, Landroid/net/Uri;->toString()Ljava/lang/String;
    move-result-object v1
    invoke-virtual {v0, v1}, Ljava/util/HashSet;->add(Ljava/lang/Object;)Z
    :cond_check
    sget-object v0, Lcom/oplus/camera/helper/LosGalleryFallback;->sPendingUri:Landroid/net/Uri;
    if-eqz v0, :cond_out
    if-eqz p0, :cond_go
    invoke-virtual {v0, p0}, Landroid/net/Uri;->equals(Ljava/lang/Object;)Z
    move-result v1
    if-eqz v1, :cond_out
    :cond_go
    sget-object v1, Lcom/oplus/camera/helper/LosGalleryFallback;->sPendingAct:Landroid/app/Activity;
    sget-object v2, Lcom/oplus/camera/helper/LosGalleryFallback;->sPendingMime:Ljava/lang/String;
    const/4 v3, 0x0
    sput-object v3, Lcom/oplus/camera/helper/LosGalleryFallback;->sPendingUri:Landroid/net/Uri;
    sput-object v3, Lcom/oplus/camera/helper/LosGalleryFallback;->sPendingAct:Landroid/app/Activity;
    sput-object v3, Lcom/oplus/camera/helper/LosGalleryFallback;->sPendingMime:Ljava/lang/String;
    invoke-static {}, Lcom/oplus/camera/helper/LosGalleryFallback;->handler()Landroid/os/Handler;
    move-result-object p0
    invoke-virtual {p0, v3}, Landroid/os/Handler;->removeCallbacksAndMessages(Ljava/lang/Object;)V
    invoke-static {v1, v0, v2}, Lcom/oplus/camera/helper/LosGalleryFallback;->launch(Landroid/app/Activity;Landroid/net/Uri;Ljava/lang/String;)V
    :cond_out
    return-void
.end method

# any thread: the processed image for this uri has been written
.method public static onFinalSaved(Landroid/net/Uri;)V
    .locals 3
    if-eqz p0, :cond_done
    :try_start_0
    invoke-static {}, Lcom/oplus/camera/helper/LosGalleryFallback;->handler()Landroid/os/Handler;
    move-result-object v0
    new-instance v1, Lcom/oplus/camera/helper/LosGalleryFallback$Fire;
    invoke-direct {v1, p0}, Lcom/oplus/camera/helper/LosGalleryFallback$Fire;-><init>(Landroid/net/Uri;)V
    invoke-virtual {v0, v1}, Landroid/os/Handler;->post(Ljava/lang/Runnable;)Z
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0
    :catch_0
    :cond_done
    return-void
.end method

# main thread, from GalleryHelper when the OnePlus gallery is missing
.method public static open(Landroid/app/Activity;Lxm/i;)V
    .locals 8
    if-eqz p0, :cond_done
    if-eqz p1, :cond_done
    iget-object v0, p1, Lxm/i;->b:Landroid/net/Uri;
    if-eqz v0, :cond_done
    iget-object v1, p1, Lxm/i;->c:Ljava/lang/String;
    if-nez v1, :cond_type
    const-string v1, "image/*"
    :cond_type
    :try_start_0
    const-string v2, "image/"
    invoke-virtual {v1, v2}, Ljava/lang/String;->startsWith(Ljava/lang/String;)Z
    move-result v2
    if-eqz v2, :cond_now
    sget-object v2, Lcom/oplus/camera/helper/LosGalleryFallback;->sSaved:Ljava/util/HashSet;
    invoke-virtual {v0}, Landroid/net/Uri;->toString()Ljava/lang/String;
    move-result-object v3
    invoke-virtual {v2, v3}, Ljava/util/HashSet;->contains(Ljava/lang/Object;)Z
    move-result v2
    if-nez v2, :cond_now
    invoke-static {}, Ljava/lang/System;->currentTimeMillis()J
    move-result-wide v2
    iget-wide v4, p1, Lxm/i;->f:J
    sub-long/2addr v2, v4
    const-wide/32 v4, 0xea60
    cmp-long v6, v2, v4
    if-gez v6, :cond_now
    # wait for the processed image (or 8 s)
    sput-object p0, Lcom/oplus/camera/helper/LosGalleryFallback;->sPendingAct:Landroid/app/Activity;
    sput-object v0, Lcom/oplus/camera/helper/LosGalleryFallback;->sPendingUri:Landroid/net/Uri;
    sput-object v1, Lcom/oplus/camera/helper/LosGalleryFallback;->sPendingMime:Ljava/lang/String;
    invoke-static {}, Lcom/oplus/camera/helper/LosGalleryFallback;->handler()Landroid/os/Handler;
    move-result-object v2
    const/4 v3, 0x0
    invoke-virtual {v2, v3}, Landroid/os/Handler;->removeCallbacksAndMessages(Ljava/lang/Object;)V
    new-instance v4, Lcom/oplus/camera/helper/LosGalleryFallback$Fire;
    invoke-direct {v4, v3}, Lcom/oplus/camera/helper/LosGalleryFallback$Fire;-><init>(Landroid/net/Uri;)V
    const-wide/16 v5, 0x1f40
    invoke-virtual {v2, v4, v5, v6}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z
    goto :cond_done
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0
    :catch_0
    :cond_now
    invoke-static {p0, v0, v1}, Lcom/oplus/camera/helper/LosGalleryFallback;->launch(Landroid/app/Activity;Landroid/net/Uri;Ljava/lang/String;)V
    :cond_done
    return-void
.end method
