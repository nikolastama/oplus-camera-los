package com.oplus.osense.complexscene;

import android.os.Binder;
import android.os.Bundle;
import android.os.IBinder;
import android.os.IInterface;
import android.os.Parcel;
import android.os.RemoteException;
import java.util.List;

/** Hand-written equivalent of IComplexSceneObserver.aidl (oneway). */
public interface IComplexSceneObserver extends IInterface {
    String DESCRIPTOR = "com.oplus.osense.complexscene.IComplexSceneObserver";

    void onChanged(int eventId, List<Bundle> bundleList) throws RemoteException;

    abstract class Stub extends Binder implements IComplexSceneObserver {
        static final int TRANSACTION_onChanged = IBinder.FIRST_CALL_TRANSACTION;

        public Stub() {
            attachInterface(this, DESCRIPTOR);
        }

        public static IComplexSceneObserver asInterface(IBinder obj) {
            if (obj == null) return null;
            IInterface iin = obj.queryLocalInterface(DESCRIPTOR);
            return iin instanceof IComplexSceneObserver ? (IComplexSceneObserver) iin : null;
        }

        @Override
        public IBinder asBinder() {
            return this;
        }

        @Override
        protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
                throws RemoteException {
            if (code == TRANSACTION_onChanged) {
                data.enforceInterface(DESCRIPTOR);
                int eventId = data.readInt();
                List<Bundle> list = data.createTypedArrayList(Bundle.CREATOR);
                onChanged(eventId, list);
                return true;
            }
            return super.onTransact(code, data, reply, flags);
        }
    }
}
