// Private, short-lived recovery for one enrolment recording. Metadata and the
// video are committed together; object URLs are never persisted across reloads.
window.FaceTrackPending = (() => {
  const name = 'facetrack-pending-enrolment-v1';
  let currentUrl;
  const open = () => new Promise((resolve, reject) => {
    const request = indexedDB.open(name, 1);
    request.onupgradeneeded = () => request.result.createObjectStore('clips');
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  const transact = async (mode, action) => {
    const db = await open();
    try {
      return await new Promise((resolve, reject) => {
        const transaction = db.transaction('clips', mode);
        const request = action(transaction.objectStore('clips'));
        let result;
        request.onsuccess = () => { result = request.result; };
        request.onerror = () => reject(request.error);
        transaction.oncomplete = () => resolve(result);
        transaction.onerror = () => reject(transaction.error);
        transaction.onabort = () => reject(transaction.error);
      });
    } finally { db.close(); }
  };
  return {
    async read() {
      const entry = await transact('readonly', store => store.get('current'));
      if (!entry) return null;
      const metadata = JSON.parse(entry.metadata);
      currentUrl ??= URL.createObjectURL(entry.video);
      metadata.path = currentUrl;
      return JSON.stringify(metadata);
    },
    async save(metadata, path) {
      const response = await fetch(path);
      if (!response.ok) throw new Error('Saved recording is unavailable.');
      const video = await response.blob();
      await transact('readwrite', store => store.put({ metadata, video }, 'current'));
      currentUrl = path;
    },
    async clear() {
      await transact('readwrite', store => store.delete('current'));
      if (currentUrl) URL.revokeObjectURL(currentUrl);
      currentUrl = null;
    },
  };
})();
