// Plantilla de pm2 para una app propia. Convenciones del server:
//  - Escuchar SOLO en 127.0.0.1 (nginx es el único que entra). Next standalone: HOSTNAME;
//    `next start`: -H 127.0.0.1. Ojo: con Next 16 y rewrites en el proxy/middleware,
//    `-H 127.0.0.1` rompe la URL interna del rewrite (500 con EPROTO): ahí dejarlo en
//    0.0.0.0, que igual lo tapa ufw.
//  - Logs del proyecto en su carpeta, con timestamp, rotados por logrotate
//    (configs/logrotate/app-logs.example).
//  - Cambiar args/out_file/error_file no toma efecto con `pm2 restart`:
//    pm2 delete <app> && pm2 start ecosystem.config.js && pm2 save
module.exports = {
  apps: [
    {
      name: "mi-app",
      cwd: "/home/USUARIO/mi-app",
      script: "node_modules/next/dist/bin/next",
      args: "start -p 3000 -H 127.0.0.1",
      env: { NODE_ENV: "production" },
      max_memory_restart: "600M",
      time: true,
      out_file: "/home/USUARIO/mi-app/logs/out.log",
      error_file: "/home/USUARIO/mi-app/logs/error.log",
    },
  ],
};
