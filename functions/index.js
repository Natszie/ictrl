const functions = require("firebase-functions");
const admin = require("firebase-admin");
admin.initializeApp();

function generateConnectionId() {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  return Array.from({length: 8}, () =>
    chars[Math.floor(Math.random() * chars.length)],
  ).join("");
}

// Cloud Function to create/update paired device
exports.createPairedDevice = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
        "unauthenticated", "User must be authenticated",
    );
  }

  const {deviceInfo} = data;
  const userId = context.auth.uid;

  if (!deviceInfo || !deviceInfo.platform) {
    throw new functions.https.HttpsError(
        "invalid-argument", "Device info is required",
    );
  }

  try {
    console.log(`Creating paired device for user: ${userId}`);
    console.log("Device info:", deviceInfo);

    const connectionId = generateConnectionId();
    let query;

    if (deviceInfo.platform === "Android") {
      if (!deviceInfo.androidId || !deviceInfo.brand || !deviceInfo.model) {
        throw new functions.https.HttpsError(
            "invalid-argument", "Missing required Android device info",
        );
      }
      query = admin.firestore()
          .collection("paired_devices")
          .where("deviceInfo.androidId", "==", deviceInfo.androidId)
          .where("deviceInfo.brand", "==", deviceInfo.brand)
          .where("deviceInfo.model", "==", deviceInfo.model)
          .limit(1);
    } else if (deviceInfo.platform === "iOS") {
      if (!deviceInfo.identifierForVendor) {
        throw new functions.https.HttpsError(
            "invalid-argument", "Missing required iOS device info",
        );
      }
      query = admin.firestore()
          .collection("paired_devices")
          .where("deviceInfo.identifierForVendor", "==", deviceInfo.identifierForVendor)
          .limit(1);
    } else {
      throw new functions.https.HttpsError(
          "invalid-argument", "Unsupported platform",
      );
    }

    const existingDevices = await query.get();

    if (!existingDevices.empty) {
      const existingDoc = existingDevices.docs[0];
      const existingData = existingDoc.data();

      await existingDoc.ref.update({
        userId: userId,
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        deviceInfo: deviceInfo,
        connectionId: existingData.connectionId || connectionId,
        connected_devices: existingData.connected_devices || [],
      });

      console.log(`✅ Updated existing paired device: ${existingDoc.id}`);
      return {
        success: true,
        docId: existingDoc.id,
        updated: true,
        connectionId: existingData.connectionId || connectionId,
      };
    } else {
      const docRef = await admin.firestore().collection("paired_devices").add({
        userId: userId,
        connectionId: connectionId,
        deviceInfo: deviceInfo,
        connected_devices: [],
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
      });

      console.log(`✅ Created new paired device: ${docRef.id}`);
      return {
        success: true,
        docId: docRef.id,
        updated: false,
        connectionId: connectionId,
      };
    }
  } catch (error) {
    console.error("Error creating paired device:", error);
    throw new functions.https.HttpsError(
        "internal", "Failed to create paired device: " + error.message,
    );
  }
});

exports.getUserPairedDevices = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError(
        "unauthenticated", "User must be authenticated",
    );
  }

  const userId = context.auth.uid;

  try {
    const devicesSnapshot = await admin.firestore()
        .collection("paired_devices")
        .where("userId", "==", userId)
        .get();

    const devices = [];
    devicesSnapshot.forEach((doc) => {
      devices.push({
        id: doc.id,
        ...doc.data(),
      });
    });

    return {success: true, devices: devices};
  } catch (error) {
    console.error("Error getting paired devices:", error);
    throw new functions.https.HttpsError(
        "internal", "Failed to get paired devices",
    );
  }
});

// HTTP endpoint for violation logging
exports.logViolation = functions.https.onRequest(async (req, res) => {
  if (req.method !== "POST") {
    return res.status(405).send("Only POST allowed");
  }
  const violation = req.body;
  try {
    const docRef = await admin.firestore().collection("violations").add({
      ...violation,
      serverTimestamp: admin.firestore.FieldValue.serverTimestamp(),
    });
    res.status(200).send({success: true, docId: docRef.id});
  } catch (error) {
    res.status(500).send({success: false, error: error.message});
  }
});

exports.notifyParentOnTaskVerify = functions.firestore
  .document('task_and_rewards/{connectionId}')
  .onUpdate(async (change, context) => {
    const before = change.before.data();
    const after = change.after.data();

    const oldTasks = before.tasks || [];
    const newTasks = after.tasks || [];

    for (let i = 0; i < newTasks.length; i++) {
      const oldStatus = oldTasks[i]?.reward?.status;
      const newStatus = newTasks[i]?.reward?.status;
      if (oldStatus !== 'verify' && newStatus === 'verify') {
        const parentDeviceId = newTasks[i].parentDeviceId;
        const parentTokenDoc = await admin.firestore().collection('parent_tokens').doc(parentDeviceId).get();
        if (!parentTokenDoc.exists) continue;
        const parentToken = parentTokenDoc.data().token;
        if (!parentToken) continue;

        await admin.messaging().sendToDevice(parentToken, {
          notification: {
            title: "Task Needs Verification",
            body: `Your child completed '${newTasks[i].task}'. Please review and grant the reward.`,
          },
          data: {
            connectionId: context.params.connectionId,
            task: newTasks[i].task,
          }
        });
      }
    }
    return null;
  });
