import { io } from 'socket.io-client';
const r = await fetch('http://localhost:3000/api/auth/login', {
  method: 'POST', headers: {'content-type':'application/json'},
  body: JSON.stringify({provider:'guest', deviceId:'peek-observer', displayName:'Peek'}),
});
const { token } = await r.json();
const s = io('http://localhost:3000', { auth:{token}, transports:['websocket'] });
s.on('connect', () => s.emit('lobby:list', {}, (ack) => {
  for (const t of ack.tables ?? []) {
    console.log(`${t.code}  ${t.category} boot ${t.bootAmount}  players ${t.players}  ${t.state}`);
  }
  process.exit(0);
}));
setTimeout(() => { console.log('timeout'); process.exit(1); }, 6000);
