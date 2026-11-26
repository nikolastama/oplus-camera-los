.class public Lcom/oplus/app/OplusHansFreezeManager;
.super Ljava/lang/Object;
.source "OplusHansFreezeManager.java"

# LineageOS has no app-freezing service: the camera only fetches the instance.


# static fields
.field private static sInstance:Lcom/oplus/app/OplusHansFreezeManager;


# direct methods
.method private constructor <init>()V
    .registers 1

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method

.method public static declared-synchronized getInstance()Lcom/oplus/app/OplusHansFreezeManager;
    .registers 2

    const-class v1, Lcom/oplus/app/OplusHansFreezeManager;

    monitor-enter v1

    :try_start
    sget-object v0, Lcom/oplus/app/OplusHansFreezeManager;->sInstance:Lcom/oplus/app/OplusHansFreezeManager;

    if-nez v0, :done

    new-instance v0, Lcom/oplus/app/OplusHansFreezeManager;

    invoke-direct {v0}, Lcom/oplus/app/OplusHansFreezeManager;-><init>()V

    sput-object v0, Lcom/oplus/app/OplusHansFreezeManager;->sInstance:Lcom/oplus/app/OplusHansFreezeManager;

    :done
    monitor-exit v1
    :try_end
    .catchall {:try_start .. :try_end} :error

    return-object v0

    :error
    move-exception v0

    monitor-exit v1

    throw v0
.end method
