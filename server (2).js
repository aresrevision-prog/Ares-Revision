// Ares Revision — © 2026 MagicWinter. All Rights Reserved.
// This file is part of Ares Revision. No part of it may be copied, modified,
// or redistributed without prior written permission. See LICENSE.
//
// Private GUN sync relay — lets student/parent/school data sync between devices.
// Keep this running (Render's free tier keeps it alive automatically).

const express = require('express');
const Gun = require('gun');

const app = express();
const port = process.env.PORT || 8765;

// Simple landing page so you can confirm it's alive by visiting the URL directly
app.get('/', (req, res) => {
  res.send('✅ Ares GUN relay is running and ready.');
});

const server = app.listen(port, () => {
  console.log('Ares GUN relay listening on port ' + port);
});

Gun({ web: server });
