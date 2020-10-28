# digital-ocean-firewall-updater

args:

  --version  Muestra número de versión                                              [booleano]
  -p, --ports    Comma separated list of ports to apply firewall rule access.       [cadena de caracteres]
  -c, --cidr     Specify if IP should be saved in cidr like xxx.xxx.xxx.0/24        [booleano]
  -f, --force    Force firewall update                                              [booleano]
  -a, --add      To determinate if new IP should be added to previously saved ones. [booleano]
  -r, --remove   To remove IP addresses on selected ports. Allowing no connection.  [booleano]
  -h, --help     Muestra ayuda                                                      [booleano]