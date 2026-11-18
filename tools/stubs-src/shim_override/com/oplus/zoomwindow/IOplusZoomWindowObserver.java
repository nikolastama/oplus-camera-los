package com.oplus.zoomwindow;

import android.os.Binder;
import android.os.IBinder;
import android.os.IInterface;
import android.os.RemoteException;

/** Hand-written equivalent of IOplusZoomWindowObserver.aidl. LineageOS has no zoom-window
 *  service, so callbacks are never delivered; only the local Stub shape is needed. */
public interface IOplusZoomWindowObserver extends IInterface {
    String DESCRIPTOR = "com.oplus.zoomwindow.IOplusZoomWindowObserver";

    void onInputMethodChanged(boolean isShown) throws RemoteException;
    void onZoomWindowDied(String appName) throws RemoteException;
    void onZoomWindowHide(OplusZoomWindowInfo info) throws RemoteException;
    void onZoomWindowShow(OplusZoomWindowInfo info) throws RemoteException;

    abstract class Stub extends Binder implements IOplusZoomWindowObserver {
        public Stub() {
            attachInterface(this, DESCRIPTOR);
        }

        public static IOplusZoomWindowObserver asInterface(IBinder obj) {
            if (obj == null) return null;
            IInterface iin = obj.queryLocalInterface(DESCRIPTOR);
            return iin instanceof IOplusZoomWindowObserver ? (IOplusZoomWindowObserver) iin : null;
        }

        @Override
        public IBinder asBinder() {
            return this;
        }
    }
}
