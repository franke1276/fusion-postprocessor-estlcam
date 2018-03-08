/*

estlCAM Post-Processor for Fusion 360
Using Exiting Post Processors as inspiration
For documentation, see GitHub Wiki : https://github.com/Strooom/GRBL-Post-Processor/wiki

Please notice ESTLCAM does not support other than XY circular movements. (no G18/19)
For that please make sure, that on a milling operation in Fusion 360
on the tab "Anfahrt-Wegfahrbewegungen" / "Vertikaler Einfahrradius" is set to 0 mm
*/

description = "estlCAM Post-Processor for Fusion 360";
vendor = "Franke";
vendorUrl = "";
model = "";
legal = "Copyright (C) 2012-2016 by Autodesk, Inc.";
certificationLevel = 2;

extension = "nc";
setCodePage("ascii");

capabilities = CAPABILITY_MILLING
tolerance = spatial(0.005, MM);
minimumChordLength = spatial(0.01, MM);
minimumCircularRadius = spatial(0.01, MM);
maximumCircularRadius = spatial(1000, MM);
minimumCircularSweep = toRad(0.01);
maximumCircularSweep = toRad(180);
allowHelicalMoves = true;
allowedCircularPlanes = undefined;

var ESTLCAMunits = MM;


// creation of all kinds of G-code formats - controls the amount of decimals used in the generated G-Code
var gFormat = createFormat({prefix:"G", decimals:0});
var mFormat = createFormat({prefix:"M", decimals:0});

var xyzFormat = createFormat({decimals:(unit == MM ? 3 : 4)});
var arcFormat = createFormat({decimals:(unit == MM ? 4 : 5)});    // uses extra digit in arcs
var feedFormat = createFormat({decimals:0});
var rpmFormat = createFormat({decimals:0});

var xOutput = createVariable({prefix:"X"}, xyzFormat);
var yOutput = createVariable({prefix:"Y"}, xyzFormat);
var zOutput = createVariable({prefix:"Z"}, xyzFormat);
var feedOutput = createVariable({prefix:"F"}, feedFormat);
var sOutput = createVariable({prefix:"S", force:true}, rpmFormat);

// for arcs, use extra digit
var xaOutput = createVariable({prefix:"X"}, arcFormat);
var yaOutput = createVariable({prefix:"Y"}, arcFormat);
var zaOutput = createVariable({prefix:"Z"}, arcFormat);

var iOutput = createVariable({prefix:"I"}, arcFormat);
var jOutput = createVariable({prefix:"J"}, arcFormat);
var kOutput = createVariable({prefix:"K"}, arcFormat);







function writeBlock() {
	writeWords(arguments);
}

function writeComment(text)	{
	// Remove special characters which could confuse GRBL : $, !, ~, ?, (, )
	// In order to make it simple, I replace everything which is not A-Z, 0-9, space, : , .
	// Finally put everything between () as this is the way GRBL & UGCS expect comments
	writeln("(" + String(text).replace(/[^a-zA-Z\d :=,.]+/g, " ") + ")");
}

function onOpen()	{
	// Number of checks capturing fatal errors
	// 1. is CAD file in same units as our GRBL configuration ?
	if (unit != ESTLCAMunits) {
		if (ESTLCAMunits == MM) {
			alert("Error", "ESTLCAM configured to mm - CAD file sends Inches! - Change units in CAD/CAM software to mm");
			error("Fatal Error : units mismatch between CADfile and ESTLCAM setting");
		}	else {
			alert("Error", "ESTLCAM configured to inches - CAD file sends mm! - Change units in CAD/CAM software to inches");
			error("Fatal Error : units mismatch between CADfile and ESTLCAM setting");
		}
	}

	// 2. is RadiusCompensation not set incorrectly ?
	onRadiusCompensation();


	var productName = getProduct();
	writeComment("Made in : " + productName);

	if (programName) {
		writeComment("Program Name : " + programName);
	}
	if (programComment) {
		writeComment("Program Comments : " + programComment);
	}

	var numberOfSections = getNumberOfSections();
	writeComment(numberOfSections + " Operation" + ((numberOfSections == 1)?"":"s") + " :");
}

function onComment(message)	{
	writeComment(message);
}

function forceXYZ()	{
	xOutput.reset();
	yOutput.reset();
	zOutput.reset();
}

function forceAny() {
	forceXYZ();
	feedOutput.reset();
}

function onSection() {
	var nmbrOfSections = getNumberOfSections();
	var sectionId = getCurrentSectionId();
	var section = getSection(sectionId);

	// Insert a small comment section to identify the related G-Code in a large multi-operations file
	var comment = "Operation " + (sectionId + 1) + " of " + nmbrOfSections;
	if (hasParameter("operation-comment")) {
		comment = comment + " : " + getParameter("operation-comment");
	}
	writeComment(comment);
	writeln("");

	var tool = section.getTool();

	if(!isFirstSection()) {
		var previousTool = getSection(sectionId - 1).getTool();
		if (tool.getDescription() != previousTool.getDescription()) {
			writeBlock(mFormat.format(6), "(" + tool.getDescription() + ")");
		}
	}

	writeBlock(mFormat.format(3), sOutput.format(tool.spindleRPM));

	// If the machine has coolant, write M8 or M9
	if (properties.hasCoolant) {
		if (tool.coolant)	{
			writeBlock(mFormat.format(8));
		}	else {
			writeBlock(mFormat.format(9));
		}
	}

	forceXYZ();

	var remaining = currentSection.workPlane;
	if (!isSameDirection(remaining.forward, new Vector(0, 0, 1))) {
		alert("Error", "Tool-Rotation detected - only supports 3 Axis");
		error("Fatal Error in Operation " + (sectionId + 1) + ": Tool-Rotation detected but only supports 3 Axis");
	}
	setRotation(remaining);

	forceAny();

	// Rapid move to initial position, first XY, then Z
	var initialPosition = getFramePosition(currentSection.getInitialPosition());
	writeBlock("G00", xOutput.format(initialPosition.x), yOutput.format(initialPosition.y));
	writeBlock("G00", zOutput.format(initialPosition.z));
}


function onSpindleSpeed(spindleSpeed) {
	writeBlock(sOutput.format(spindleSpeed));
}

function onRadiusCompensation() {
	var radComp = getRadiusCompensation();
	var sectionId = getCurrentSectionId();
	if (radComp != RADIUS_COMPENSATION_OFF)	{
		alert("Error", "RadiusCompensation is not supported in ESTLCAM - Change RadiusCompensation in CAD/CAM software to Off/Center/Computer");
		error("Fatal Error in Operation " + (sectionId + 1) + ": RadiusCompensation is found in CAD file but is not supported in ESTLCAM");
		return;
	}
}

function onRapid(_x, _y, _z) {
	var x = xOutput.format(_x);
	var y = yOutput.format(_y);
	var z = zOutput.format(_z);

	writeBlock("G00", x, y, z);
	feedOutput.reset();
}

function onLinear(_x, _y, _z, feed) {
	var x = xOutput.format(_x);
	var y = yOutput.format(_y);
	var z = zOutput.format(_z);
	var f = feedOutput.format(feed);

	if (x || y || z) {
		writeBlock("G01", x, y, z, f);
	}	else if (f)	{
		if (getNextRecord().isMotion())	{
			feedOutput.reset();
		}	else {
			writeBlock("G01", f);
		}
	}
}

function onRapid5D(_x, _y, _z, _a, _b, _c) {
	alert("Error", "Tool-Rotation detected - ESTLCAM only supports 3 Axis");
	error("Tool-Rotation detected but ESTLCAM only supports 3 Axis");
}

function onLinear5D(_x, _y, _z, _a, _b, _c, feed) {
	alert("Error", "Tool-Rotation detected - ESTLCAM only supports 3 Axis");
	error("Tool-Rotation detected but ESTLCAM only supports 3 Axis");
}

function onCircular(clockwise, cx, cy, cz, x, y, z, feed) {
	var start = getCurrentPosition();
	if (isFullCircle())	{
		if (isHelical()) {
			linearize(tolerance);
			return;
		}

		switch (getCircularPlane())	{
			case PLANE_XY:
				writeBlock(clockwise ? "G02" : "G03", xaOutput.format(x), iOutput.format(cx - start.x), jOutput.format(cy - start.y), feedOutput.format(feed));
				break;
			case PLANE_ZX:
				alert("Error", "No PLANE_ZX,  only XY-PLANE");
				error("only XY-PLANE");
				break;
			case PLANE_YZ:
				alert("Error", "No PLANE_YZ, only XY-PLANE");
				error("only XY-PLANE");
				break;
			default:
				linearize(tolerance);
			}
		} else {
		switch (getCircularPlane())	{
			case PLANE_XY:
				writeBlock(clockwise ? "G02" : "G03", xaOutput.format(x), yaOutput.format(y), zaOutput.format(z), iOutput.format(cx - start.x), jOutput.format(cy - start.y), feedOutput.format(feed));
				break;
			case PLANE_ZX:
				alert("Error", "No PLANE ZX, only XY-PLANE");
				error("only XY-PLANE");
				break;
			case PLANE_YZ:
				alert("Error", "No PLANE YZ, only XY-PLANE");
				error("only XY-PLANE");
				break;
			default:
				linearize(tolerance);
			}
		}
}

function onSectionEnd() {
}

function onClose() {
	writeBlock("G00", xOutput.format(0), yOutput.format(0));
}
