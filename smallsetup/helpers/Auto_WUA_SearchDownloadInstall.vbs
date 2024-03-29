on error resume next

const L_Msg01_Text = 	"Searching for recommended updates..."

const L_Msg02_Text = 	"List of applicable items on the machine:"
const L_Msg03_Text = 	"There are no applicable updates."
const L_Msg04_Text = 	"Press return to continue..."
const L_Msg05_Text = 	"Select an option:"
const L_Msg06_Text = 	"Downloading updates..."
const L_Msg07_Text = 	"Installing updates..."
const L_Msg08_Text = 	"Listing of updates installed and individual installation results:"
const L_Msg09_Text = 	"Installation Result: "
const L_Msg10_Text = 	"Restart Required:  "
const L_Msg11_Text = 	"A restart is required to complete Windows Updates. Restart now?"
const L_Msg12_Text = 	"Press return to continue..."
const L_Msg13_Text = 	"Not Started"
const L_Msg14_Text = 	"In Progress"
const L_Msg15_Text = 	"Succeeded"
const L_Msg16_Text = 	"Succeeded with errors"
const L_Msg17_Text = 	"Failed"
const L_Msg18_Text = 	"Process stopped before completing"
const L_Msg19_Text = 	"Restart Required"
const L_Msg20_Text = 	"N"   'No
const L_Msg21_Text = 	"Y"   'Yes
const L_Msg22_Text = 	"Searching for all applicable updates..."
const L_Msg23_Text = 	"Search for for (A)ll updates or (R)ecommended updates only? "
const L_Msg24_Text = 	"A"  ' All
const L_Msg25_Text = 	"R"  ' Recommended only
const L_Msg26_Text = 	"S"  ' Single update only
const L_Msg27_Text = 	"Enter the number of the update to download and install:"
const L_Msg28_Text = 	"(A)ll updates, (N)o updates or (S)elect a single update? "


Set updateSession = CreateObject("Microsoft.Update.Session")
Set updateSearcher = updateSession.CreateupdateSearcher()
Set oShell = WScript.CreateObject ("WScript.shell")


Do
wscript.StdOut.Write L_Msg23_Text       
' dietrich
'UpdatesToSearch = ucase(Wscript.StdIn.ReadLine)
UpdatesToSearch = "A"
WScript.Echo

Select Case UpdatesToSearch

  Case L_Msg24_Text 'All
	WScript.Echo L_Msg22_Text & vbCRLF
	Set searchResult = updateSearcher.Search("IsInstalled=0 and Type='Software'")

  Case  L_Msg25_Text ' Recommended
	WScript.Echo L_Msg01_Text & vbCRLF
	Set searchResult = updateSearcher.Search("IsInstalled=0 and Type='Software' and AutoSelectOnWebsites=1")

  Case Else
	'
end Select 
Loop until UpdatesToSearch=L_Msg24_Text or UpdatesToSearch=L_Msg25_Text

WScript.Echo L_Msg02_Text
WScript.Echo

For I = 0 To searchResult.Updates.Count-1
    Set update = searchResult.Updates.Item(I)
    WScript.Echo I + 1 & "> " & update.Title
Next

SingleUpdateSelected=""

If searchResult.Updates.Count = 0 Then
	WScript.Echo
	WScript.Echo L_Msg03_Text
	WScript.Echo
	wscript.StdOut.Write L_Msg04_Text
	'Wscript.StdIn.ReadLine
	WScript.Quit
else

	'Select updates to download

	do
	  WScript.Echo vbCRLF & L_Msg05_Text
	  Wscript.StdOut.Write L_Msg28_Text
	  'UpdateSelection = ucase(WScript.StdIn.Readline)
	  UpdateSelection = "A"
	  WScript.Echo 
	loop until UpdateSelection=ucase(L_Msg20_Text) or UpdateSelection=ucase(L_Msg24_Text) or UpdateSelection=ucase(L_Msg26_Text)

	If UpdateSelection=ucase(L_Msg20_Text) Then 'No updates
		WScript.Quit
	end if
	
	If UpdateSelection=ucase(L_Msg26_Text) Then 'Single update
		Do
		    WScript.Echo  vbCRLF & L_Msg27_Text
		    SingleUpdateSelected = WScript.StdIn.Readline	
		loop until cint(SingleUpdateSelected) > 0 and cint(SingleUpdateSelected) <= searchResult.Updates.Count
	end if

End If


Set updatesToDownload = CreateObject("Microsoft.Update.UpdateColl")

For I = 0 to searchResult.Updates.Count-1
    if SingleUpdateSelected="" then 
	Set update = searchResult.Updates.Item(I)
    	updatesToDownload.Add(update)
    else
	if I=cint(SingleUpdateSelected)-1 then 
	    Set update = searchResult.Updates.Item(I)
	    updatesToDownload.Add(update)
	end if
    end if
Next

WScript.Echo vbCRLF & L_Msg06_Text
WScript.Echo

Set downloader = updateSession.CreateUpdateDownloader() 
downloader.Updates = updatesToDownload
downloader.Download()

Set updatesToInstall = CreateObject("Microsoft.Update.UpdateColl")

'Creating collection of downloaded updates to install 

For I = 0 To searchResult.Updates.Count-1
    set update = searchResult.Updates.Item(I)
    If update.IsDownloaded = true Then
        updatesToInstall.Add(update)	
    End If
Next

WScript.Echo
WScript.Echo L_Msg07_Text & vbCRLF
Set installer = updateSession.CreateUpdateInstaller()
installer.Updates = updatesToInstall
Set installationResult = installer.Install()

WScript.Echo L_Msg08_Text & vbCRLF
	
For I = 0 to updatesToInstall.Count - 1

	WScript.Echo I + 1 & "> " & _
	updatesToInstall.Item(i).Title & _
	": " & ResultCodeText(installationResult.GetUpdateResult(i).ResultCode)		
Next
	
'Output results of install
WScript.Echo
WScript.Echo L_Msg09_Text & ResultCodeText(installationResult.ResultCode)
WScript.Echo L_Msg10_Text & installationResult.RebootRequired & vbCRLF 

If installationResult.RebootRequired then
		'confirm = msgbox(L_Msg11_Text, vbYesNo+vbDefaultButton2+vbSystemModal,L_Msg19_Text)
		'if confirm=vbYes then oShell.Run "shutdown /r /t 0",1	
		wscript.echo "running oShell.Run shutdown /r /t 0,1"
		oShell.Run "shutdown /r /t 60",1	
end if

WScript.Echo
Wscript.StdOut.Write L_Msg12_Text
'Wscript.StdIn.ReadLine
WScript.Quit	

Function ResultCodeText(resultcode)
	if resultcode=0 then ResultCodeText=L_Msg13_Text
	if resultcode=1 then ResultCodeText=L_Msg14_Text
	if resultcode=2 then ResultCodeText=L_Msg15_Text
	if resultcode=3 then ResultCodeText=L_Msg16_Text
	if resultcode=4 then ResultCodeText=L_Msg17_Text
	if resultcode=5 then ResultCodeText=L_Msg18_Text
end Function	
'' SIG '' Begin signature block
'' SIG '' MIIGCwYJKoZIhvcNAQcCoIIF/DCCBfgCAQExDzANBglg
'' SIG '' hkgBZQMEAgEFADB3BgorBgEEAYI3AgEEoGkwZzAyBgor
'' SIG '' BgEEAYI3AgEeMCQCAQEEEE7wKRaZJ7VNj+Ws4Q8X66sC
'' SIG '' AQACAQACAQACAQACAQAwMTANBglghkgBZQMEAgEFAAQg
'' SIG '' qW6SN2SwDdoWkFN22gNkU+AxOHb8tMNOocVDtixH9qCg
'' SIG '' ggNyMIIDbjCCAlagAwIBAgIQJjtI8pNKUqhMfE8pmFND
'' SIG '' sDANBgkqhkiG9w0BAQsFADA0MTIwMAYDVQQDDClTaWVt
'' SIG '' ZW5zIEhlYWx0aGNhcmUgc3luZ28gc3VwcG9ydCBzb2Z0
'' SIG '' d2FyZTAeFw0xODAxMjYxMzA4MThaFw0zODEyMzEyMzAw
'' SIG '' MDBaMDQxMjAwBgNVBAMMKVNpZW1lbnMgSGVhbHRoY2Fy
'' SIG '' ZSBzeW5nbyBzdXBwb3J0IHNvZnR3YXJlMIIBIjANBgkq
'' SIG '' hkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqdc06VOKJlHi
'' SIG '' 25FiPjTzJ8sySdjIvzv5k821BFXBVKyFZqiShuhGtJqm
'' SIG '' +pqsxSSm0eJdDAOE5m9unVmKvio6FFUhydHnWi72Dv0f
'' SIG '' UUiAoRcpcPxQVyGE++jwbvTFDmew9CV13pJHH2LUgEJB
'' SIG '' NKUv7TfmrtpDz1Zm72f9AKmkf/aepPT0Biy0ZmO8K5v3
'' SIG '' fpkMKjH8khBfsjXANJLdKwaY4JrZHRJMTVOWhhcKq5GU
'' SIG '' Uhh1qoqMM7M7wum8UPkt/KuupvpExQBbvTNtTV5FpCMe
'' SIG '' i2/BjEby8YjrHqu2C6H125Ial6OYc24WIqtMGVThQ3K/
'' SIG '' 2F0mRCzvDQCBVZ2gudAtbQIDAQABo3wwejAOBgNVHQ8B
'' SIG '' Af8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwMwNAYD
'' SIG '' VR0RBC0wK4IpU2llbWVucyBIZWFsdGhjYXJlIHN5bmdv
'' SIG '' IHN1cHBvcnQgc29mdHdhcmUwHQYDVR0OBBYEFKb/wAst
'' SIG '' p27t5V6PyRT6qdzGuNLaMA0GCSqGSIb3DQEBCwUAA4IB
'' SIG '' AQA3tgOYLjxly9JkBnedf3B9jVtHaEEa/7wyoYwZKQeQ
'' SIG '' 0bbyg9TRw0ZAlB0v9HsOQLH6u37FYA1jGPlYAy/XeJRh
'' SIG '' 0nkCXWjUOCxqDjJR9TfToOW0aQyteBzSGsEH7DX2LQya
'' SIG '' y6p9VNrdKuaUumQCek2d34yr1javy6842Np/53+1+pLD
'' SIG '' F4+FScwfc6XMYOuSA5f41xbzGacSoOYITABVQjtarJma
'' SIG '' SuFk/6OHvckJ4kB+B5XjFE8mMN5bvPo5eLEH4r08dbad
'' SIG '' hKFupBUr0reKrcUnCcNpROQ342ZFG/xw7k30AbsOHIRt
'' SIG '' RT3H9QxsFJ/BM2Ddt4/LpVdLsQOr6J8STIf/MYIB8TCC
'' SIG '' Ae0CAQEwSDA0MTIwMAYDVQQDDClTaWVtZW5zIEhlYWx0
'' SIG '' aGNhcmUgc3luZ28gc3VwcG9ydCBzb2Z0d2FyZQIQJjtI
'' SIG '' 8pNKUqhMfE8pmFNDsDANBglghkgBZQMEAgEFAKB8MBAG
'' SIG '' CisGAQQBgjcCAQwxAjAAMBkGCSqGSIb3DQEJAzEMBgor
'' SIG '' BgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEE
'' SIG '' AYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCtag0v/GKflolR
'' SIG '' mA7Y0Qrz9SxpYz3zhlbMxi6p+iiuUzANBgkqhkiG9w0B
'' SIG '' AQEFAASCAQACK8/dMNl+yTOuPBPs0ld5aGfu5ono5uSj
'' SIG '' bdpTa1tp1pc5VZ+vc+wnbFlIA1ssZU1VXXKFUjTwZhGn
'' SIG '' VHfx+XzwcSFCCuyKLDAnxmW0Bs2gERbRxSltvq+5ZU+f
'' SIG '' pGq3ctkP3it3v5dRMjA7Wl8x3cMdezEzDm/9/g8rAawk
'' SIG '' qW+dUFZeho6Z+n7Pt5Kqbqf2O4/61PMTiipNiUPws6af
'' SIG '' WWiln9+5GR6AWnFB2zzhTioXg3Pwr3fJ0c1LcDDhtc8/
'' SIG '' S4kZiVouAPV0jWxeYMQdY2nVcDAf5VF+mC58IjC/+IUC
'' SIG '' P1COAwAufD8DfZEBr6ZxsBCZIvIe2yITF8fQIWadmMgl
'' SIG '' End signature block
