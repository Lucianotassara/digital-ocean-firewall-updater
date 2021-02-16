// require('dotenv').config();
const dotenv = require("dotenv");
dotenv.config({ path: __dirname + "/.env" });

console.log(__dirname);

const fetch = require("node-fetch");
const fs = require("fs");
const util = require("util");
const yargs = require("yargs");

let ports = [];
let overwrite;
let clean, cidr, force = false;

/** args:
 *
  --version  Muestra número de versión                                              [booleano]
  -p, --ports    Comma separated list of ports to apply firewall rule access.       [cadena de caracteres]
  -c, --cidr     Specify if IP should be saved in cidr like xxx.xxx.xxx.0/24        [booleano]
  -f, --force    Force firewall update                                              [booleano]
  -a, --add      To determinate if new IP should be added to previously saved ones. [booleano]
  -r, --remove   To remove IP addresses on selected ports. Allowing no connection.  [booleano]
  -h, --help     Muestra ayuda                                                      [booleano]
 *
 * */

function toCidrNotation(ip) {
  let arr = ip.split(`.`);
  arr[3] = `0/24`;
  return arr.join(`.`);
}

function saveCurrentIpAddress(ip) {
  fs.writeFile("lastIp.txt", ip, function (err) {
    if (err) return console.log(err);
    console.log(`${ip} > lastIp.txt`);
  });
}

async function getPublicIPAddress() {
  let myPublicIp;
  const getIP = async () => {
    try {
      const response = await fetch(`http://ipv4bot.whatismyipaddress.com`, {
        method: "GET",
        headers: {
          Accept: "text/html",
          "Content-Type": "text/html",
        },
      });
      const text = await response.text();
      console.log(`Getting IP: ${text}`);
      return text;
    } catch (error) {
      console.error(error);
    }
  };
  myPublicIp = await getIP();
  return myPublicIp;
}

async function getFirewall() {
  let firewall;
  const getJson = async () => {
    try {
      const response = await fetch(
        `https://api.digitalocean.com/v2/firewalls/${process.env.FIREWALL_ID}`,
        {
          // REAL
          method: "GET",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${process.env.PERSONAL_ACCESS_TOKEN}`,
          },
        }
      );
      const json = await response.json();
      console.log(`Getting the firewall from DO API`);
      return json;
    } catch (error) {
      console.error(error);
    }
  };

  firewall = await getJson();
  return firewall;
}

async function readSavedIpAddrees() {
  // Read lastIp.txt file
  let ip;
  let readFile = util.promisify(fs.readFile);

  function getStuff() {
    return readFile("lastIp.txt", "utf8");
  }

  ip = getStuff().then((data) => {
    return data.toString();
  });
  return ip;
}

async function apiUpdFirewall(fw) {
  fetch(
    `https://api.digitalocean.com/v2/firewalls/${process.env.FIREWALL_ID}`, //REAL
    {
      method: "PUT",
      body: JSON.stringify(fw),
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${process.env.PERSONAL_ACCESS_TOKEN}`,
      },
    }
  )
    .then(function (res) {
      return res.json();
    })
    .then(function (data) {
      console.log(
        `Placing PUT request to DigitalOcean API. RESPONSE: ${JSON.stringify(
          data
        )}`
      );
    });
}

function parseArguments() {
  const argv = yargs
    .option("ports", {
      alias: "p",
      description:
        "Comma separated list of ports to apply firewall rule access.",
      type: "string",
    })
    .option("cidr", {
      alias: "c",
      description: "Specify if IP should be saved like xxx.xxx.xxx.0/24",
      type: "boolean",
    })
    .option("force", {
      alias: "f",
      description: "Force firewall update",
      type: "boolean",
    })
    .option("add", {
      alias: "a",
      description:
        "To determinate if new IP should be added to previously saved ones.",
      type: "boolean",
    })
    .option("remove", {
      alias: "r",
      description:
        "To remove IP addresses on selected ports. Allowing no connection.",
      type: "boolean",
    })
    .help()
    .alias("help", "h").argv;

    if (!process.env.PORTS){
        if (!argv.ports){
            console.log('You should specify at least one port. Run with --help option to see available options')
            ports = null;
            return;
        } else {
            ports = argv.ports
        }
    } else {
        ports = process.env.PORTS.split(',');
    }
     
    
    argv.add ? (overwrite = false) : (overwrite = true);
    argv.remove ? (clean = true) : (clean = false);
    argv.cidr ? (cidr = true) : (cidr = false);
    argv.force ? (force = true) : (force = false);

  // console.log(argv);
}

/******************************************** */

async function run() {
  console.log(`**** ${new Date()} ****`);

  parseArguments();

  if (!ports){
    return;
  }
  

  let savedIp;
  let newIp;
  try {
    newIp = await getPublicIPAddress();
    savedIp = await readSavedIpAddrees();
  } catch (e) {
    console.error(e);
  }
  console.log(`Saved IP Address: ${savedIp}`);
  // console.log(`New IP: ${newIp}`);

  // Check if IP has changed
  if (!force && savedIp === newIp) {
    console.log("No IP changes");
    return;
  }

  // Verifico si se seleccionó con notación CIDR
  let newIpAux = newIp;
  if (cidr) {
    //convierto a CIDR la ip guardada y la nueva para comparar antes de cambiar
    if (toCidrNotation(newIp) == toCidrNotation(savedIp)) {
      console.log("IP has changed but not for CIDR notation");
      return;
    } else {
      newIp = toCidrNotation(newIp);
    }
  }
  console.log("IP has changed, starting firewall update");
  saveCurrentIpAddress(newIpAux);

  let fw;
  try {
    fw = await getFirewall();
  } catch (e) {
    console.error(e);
  }
  console.log(`Showing my firewall -> ${JSON.stringify(fw)}`);

  let arr = [];

  arr.push(newIp);
  fw.firewall.inbound_rules.forEach((rule) => {
    if (rule.protocol == "tcp") {
      ports.forEach((port) => {
        if (port === rule.ports) {

          if (clean) {
            overwrite = true;
            arr = [];
            arr.push("127.0.0.1");
          }
          if (overwrite) {
            rule.sources["addresses"] = arr;
            console.log(
              `   *** Overwriting source ip for rule on port ${rule.ports} for IP ${rule.sources["addresses"]} ***`
            );
          } else {
            rule.sources["addresses"].push(newIp);
            console.log(
              `   *** Adding new source ip for rule on port ${rule.ports} for IP ${rule.sources["addresses"]} ***`
            );
          }
        }
      });
    } else {
        console.log(`Found some none TCP rules: ${JSON.stringify(rule)}`)
    }
  });


  delete fw.firewall.id;
  delete fw.firewall.created_at;
  delete fw.firewall.pending_changes;
  delete fw.firewall.status;
  delete fw.firewall.outbound_rules[0].ports;     // For ICMP should not specify port
  delete fw.firewall.inbound_rules[0].ports;      // For ICMP should not specify port
  fw.firewall.outbound_rules[1].ports = "all"
  fw.firewall.outbound_rules[2].ports = "all"
  console.log(`Showing updated firewall -> ${JSON.stringify(fw)}`);

  // Update firewall
  try {
      await apiUpdFirewall(fw.firewall);
  } catch (e) {
      console.error(e)
  }
}

run();
