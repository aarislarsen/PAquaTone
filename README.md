# PAquaTone
A (badly) implemented version of Aquatone in powershell, for use internally/in postexploitation/target selection in a domain.

I'm a big fan of Michael's Aquatone (https://github.com/michenriksen/aquatone) but sometimes all you have is powershell, and this might come in handy.

The script takes a start and end IP, and will do a reverse DNS lookup of each, then use Chrome (if installed) to browse to FQDN on a handfull of standard ports and grab a screenshot.

If you have the option of using Aquatone, you should PROBABLY USE AQUATONE, but if not, give this a shot.
