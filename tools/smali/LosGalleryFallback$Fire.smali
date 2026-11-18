.class final Lcom/oplus/camera/helper/LosGalleryFallback$Fire;
.super Ljava/lang/Object;
.source "LosGalleryFallback.java"

# interfaces
.implements Ljava/lang/Runnable;

.field private final uri:Landroid/net/Uri;

.method constructor <init>(Landroid/net/Uri;)V
    .locals 0
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    iput-object p1, p0, Lcom/oplus/camera/helper/LosGalleryFallback$Fire;->uri:Landroid/net/Uri;
    return-void
.end method

.method public final run()V
    .locals 1
    iget-object v0, p0, Lcom/oplus/camera/helper/LosGalleryFallback$Fire;->uri:Landroid/net/Uri;
    :try_start_0
    invoke-static {v0}, Lcom/oplus/camera/helper/LosGalleryFallback;->firePending(Landroid/net/Uri;)V
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0
    :catch_0
    return-void
.end method
