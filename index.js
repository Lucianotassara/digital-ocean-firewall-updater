// require('dotenv').config();
const dotenv = require('dotenv');    
dotenv.config({ path: __dirname + '/.env' });

console.log(__dirname);

const fetch = require('node-fetch');
const fs = require('fs');
const util = require('util');


function toCidrNotation(ip){
    let arr = ip.split(`.`);
    arr[3] = `0/24`;
    return arr.join(`.`);
}

function saveCurrentIpAddress(ip){    
    fs.writeFile('lastIp.txt', ip, function (err) {
        if (err) return console.log(err);
        console.log(`${ip} > lastIp.txt`);
    });
}

async function getPublicIPAddress(){
    let myPublicIp;   
    const getIP = async () => {
        try {
            const response = await fetch(`http://ipv4bot.whatismyipaddress.com`, {
            method: "GET",
            headers: {
                'Accept': 'text/html',
                'Content-Type': 'text/html'
                }
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



async function getFirewall(){   
    let firewall;   
    const getJson = async () => {
        try {
            const response = await fetch(`https://api.digitalocean.com/v2/firewalls/${process.env.FIREWALL_ID}`, {     // REAL
            method: "GET",
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${process.env.PERSONAL_ACCESS_TOKEN}`
                }
            });
            const json = await response.json();
            console.log(`Getting the firewall from DO API`)
            return json;
        } catch (error) {
            console.error(error);
        }
    };

    firewall = await getJson();
    return firewall;
}


async function readSavedIpAddrees(){
    // Read lastIp.txt file
    let ip;
    let readFile = util.promisify(fs.readFile);
    
    function getStuff() {
        return readFile('lastIp.txt', 'utf8');
    }
    
    ip = getStuff().then(data => {
        return data.toString();
    })
    return ip;
}




async function apiUpdFirewall(fw){
    fetch(`https://api.digitalocean.com/v2/firewalls/${process.env.FIREWALL_ID}`, //REAL
    {
        method: "PUT",
        body: JSON.stringify(fw),
        headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${process.env.PERSONAL_ACCESS_TOKEN}`
        },
    })
    .then(function(res){ return res.json(); })
    .then(function(data){ 
        console.log(`Placing PUT request to DigitalOcean API. RESPONSE: ${JSON.stringify( data )}`);
    })
}

/***********************************************     */


async function run() {
    let savedIp;
    let newIp;
    try{ 
        newIp = await getPublicIPAddress();
        savedIp = await readSavedIpAddrees();
    } catch(e) {
        console.error(e);
    }
    console.log(`Saved IP Address: ${savedIp}`);
    // console.log(`New IP: ${newIp}`);
    
    /***** 0. Check if IP has changed */
    if(savedIp === newIp) {
        console.log('No IP changes')
    } else {
        console.log('IP has changed, starting firewall update')
        let fw;
        try{ 
            fw = await getFirewall();
        } catch(e) {
            console.error(e);
        }
        console.log(`Muestro mi firewall -> ${JSON.stringify(fw)}`)
        
        
        let arr = [];
        arr.push(newIp);
        saveCurrentIpAddress(newIp);
        
        console.log('Changing IP for firewall rule on port 22')
        fw.firewall.inbound_rules[1].sources["addresses"] = arr; 
        console.log('Changing IP for firewall rule on port 2083')
        fw.firewall.inbound_rules[13].sources["addresses"] = arr;
        console.log('Changing IP for firewall rule on port 3306')
        fw.firewall.inbound_rules[15].sources["addresses"] = arr; 
        console.log('Changing IP for firewall rule on port 27017')
        fw.firewall.inbound_rules[17].sources["addresses"] = arr;

        delete fw.firewall.id;
        delete fw.firewall.created_at;
        delete fw.firewall.pending_changes;
        delete fw.firewall.status;
        delete fw.firewall.outbound_rules[0].ports;     // For ICMP should not specify port
        delete fw.firewall.inbound_rules[0].ports;      // For ICMP should not specify port
        fw.firewall.outbound_rules[1].ports = "all"
        fw.firewall.outbound_rules[2].ports = "all"
        // console.log(`Showing updated firewall -> ${JSON.stringify(fw)}`)
   
        /***** Update firewall */
        try {
            result = await apiUpdFirewall(fw.firewall);
        } catch (e) {
            console.error(e)
        }
        console.log(result);
    }       
}
 
run();