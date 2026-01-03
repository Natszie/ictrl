const admin = require("firebase-admin");

if (!admin.apps.length) {
  admin.initializeApp({
    credential: admin.credential.cert(require("./serviceAccountKey.json")),
  });
}

module.exports = async (req, res) => {
  if (req.method !== "POST") {
    return res.status(405).send("Only POST allowed");
  }
  try {
    console.log("Incoming body:", req.body); // Log incoming data
    const docRef = await admin.firestore().collection("violations").add({
      ...req.body,
      serverTimestamp: admin.firestore.FieldValue.serverTimestamp(),
    });
    console.log("Wrote to Firestore, docId:", docRef.id); // Log success
    return res.status(200).json({ success: true, docId: docRef.id });
  } catch (error) {
    console.error("Error writing to Firestore:", error); // Log error
    return res.status(500).json({ success: false, error: error.message });
  }
};
