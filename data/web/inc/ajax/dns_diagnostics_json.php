<?php
/***********************************************************************************************************************
 * Retrieve DNS diagnostics data from dns_diagnostics.php
 */

ob_start();
include "dns_diagnostics.php";
$dom = new DOMDocument();
$dom->loadHTML(ob_get_clean());
/*
error_reporting(E_ALL);
ini_set('display_errors', '1');
*/
$tables = $dom->getElementsByTagName('table');
if(count($tables) != 1) {
	trigger_error("Unexpected data from DNS diagnostics", E_USER_ERROR);
	return false;
}


$headers = array("name", "type", "data_correct", "data_current");
$data = array();
echo "<pre>";
foreach($tables[0]->getElementsByTagName("tr") as $row) {

	$obj = array();
	$cols = $row->getElementsByTagName("td");
	if($cols->length > 0) {
		for($i = 0; $i < count($headers); $i ++) {
			$obj[ $headers[ $i ] ] = $cols[ $i ]->nodeValue;
		}

		array_push($data, $obj);
	}
}

/***********************************************************************************************************************
 * Output data as JSON
 */
header('Content-Type: application/json');
echo json_encode($data);