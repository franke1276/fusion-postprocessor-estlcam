/*

Custom Post-Processor for GRBL based Openbuilds-style CNC machines
Using Exiting Post Processors as inspiration
For documentation, see GitHub Wiki : https://github.com/Strooom/GRBL-Post-Processor/wiki
This post-Processor should work on GRBL-based machines such as
* Openbuilds - OX, C-Beam
* Inventables - X-Carve
* ShapeOko / Carbide3D
* your spindle is Makita RT0700 or Dewalt 611

22/AUG/2016 - V1 : Kick Off
23/AUG/2016 - V2 : Added Machining Time to Operations overview at file header
24/AUG/2016 - V3 : Added extra user properties - further cleanup of unused variables
07/SEP/2016 - V4 : Added support for INCHES. Added a safe retract at beginning of first section
11/OCT/2016 - V5
30/JAN/2017 - V6 : Modified capabilities to also allow waterjet, laser-cutting..
*/

description = "Openbuilds Grbl";
vendor = "Openbuilds";
vendorUrl = "http://openbuilds.com";
model = "OX";
description = "Open Hardware Desktop CNC Router";
legal = "Copyright (C) 2012-2016 by Autodesk, Inc.";
certificationLevel = 2;

extension = "nc";										// file extension of the gcode file
setCodePage("ascii");									// character set of the gcode file
//setEOL(CRLF);											// end-of-line type : use CRLF for windows

capabilities = CAPABILITY_MILLING | CAPABILITY_JET;		// intended for a CNC, so Milling
tolerance = spatial(0.005, MM);
minimumChordLength = spatial(0.01, MM);
minimumCircularRadius = spatial(0.01, MM);
maximumCircularRadius = spatial(1000, MM);
minimumCircularSweep = toRad(0.01);
maximumCircularSweep = toRad(180);
allowHelicalMoves = true;
allowedCircularPlanes = undefined;

var GRBLunits = MM;										// GRBL controller set to mm (Metric). Allows for a consistency check between GRBL settings and CAM file output
// var GRBLunits = IN;

// user-defined properties : defaults are set, but they can be changed from a dialog box in Fusion when doing a post.
properties =
	{
	spindleOnOffDelay: 0.8,				// time (in seconds) the spindle needs to get up to speed or stop
	spindleTwoDirections : false,		// true : spindle can rotate clockwise and counterclockwise, will send M3 and M4. false : spindle can only go clockwise, will only send M3
	hasCoolant : false,					// true : machine uses the coolant output, M8 M9 will be sent. false : coolant output not connected, so no M8 M9 will be sent
	hasSpeedDial : true,				// true : the spindle is of type Makite RT0700, Dewalt 611 with a Dial to set speeds 1-6. false : other spindle
	machineHomeZ : -10,					// absolute machine coordinates where the machine will move to at the end of the job - first retracting Z, then moving home X Y
	machineHomeX : -10,
	machineHomeY : -10
	};

// creation of all kinds of G-code formats - controls the amount of decimals used in the generated G-Code
var gFormat = createFormat({prefix:"G", decimals:0});
var mFormat = createFormat({prefix:"M", decimals:0});

var xyzFormat = createFormat({decimals:(unit == MM ? 3 : 4)});
var arcFormat = createFormat({decimals:(unit == MM ? 4 : 5)});    // uses extra digit in arcs
var feedFormat = createFormat({decimals:0});
var rpmFormat = createFormat({decimals:0});
var secFormat = createFormat({decimals:1, forceDecimal:true});
var taperFormat = createFormat({decimals:1, scale:DEG});

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

var gMotionModal = createModal({}, gFormat); 											// modal group 1 // G0-G3, ...
var gPlaneModal = createModal({onchange:function () {gMotionModal.reset();}}, gFormat); // modal group 2 // G17-19
var gAbsIncModal = createModal({}, gFormat); 											// modal group 3 // G90-91
var gFeedModeModal = createModal({}, gFormat); 											// modal group 5 // G93-94
var gUnitModal = createModal({}, gFormat); 												// modal group 6 // G20-21

function toTitleCase(str)
	{
	// function to reformat a string to 'title case'
	return str.replace(/\w\S*/g, function(txt)
		{
		return txt.charAt(0).toUpperCase() + txt.substr(1).toLowerCase();
		});
	}

function rpm2dial(rpm)
	{
	// translates an RPM for the spindle into a dial value, eg for the Makita RT0700 and Dewalt 611 routers
	// additionaly, check that spindle rpm is between minimun and maximum of what our spindle can do

	// array which maps spindle speeds to router dial settings,
	// according to Makita RT0700 Manual : 1=10000, 2=12000, 3=17000, 4=22000, 5=27000, 6=30000
	var speeds = [0, 10000, 12000, 17000, 22000, 27000, 30000];

	if (rpm < speeds[1])
		{
		alert("Warning", rpm + " rpm is below minimum spindle RPM of " + speeds[1] + " rpm");
		return 1;
		}

	if (rpm > speeds[speeds.length - 1])
		{
		alert("Warning", rpm + " rpm is above maximum spindle RPM of " + speeds[speeds.length - 1] + " rpm");
		return (speeds.length - 1);
		}

	var i;
	for (i=1; i < (speeds.length-1); i++)
		{
		if ((rpm >= speeds[i]) && (rpm <= speeds[i+1]))
			{
			return ((rpm - speeds[i]) / (speeds[i+1] - speeds[i])) + i;
			}
		}

	alert("Error", "Error in calculating router speed dial..");
	error("Fatal Error calculating router speed dial");
	return 0;
	}

function writeBlock()
	{
	writeWords(arguments);
	}

function writeComment(text)
	{
	// Remove special characters which could confuse GRBL : $, !, ~, ?, (, )
	// In order to make it simple, I replace everything which is not A-Z, 0-9, space, : , .
	// Finally put everything between () as this is the way GRBL & UGCS expect comments
	writeln("(" + String(text).replace(/[^a-zA-Z\d :=,.]+/g, " ") + ")");
	}

function onOpen()
	{
	// Number of checks capturing fatal errors
	// 1. is CAD file in same units as our GRBL configuration ?
   // swarfer : GRBL obeys G20/21 so we should only need to output the correct code for the numbers we are outputting, I will look at this later
	if (unit != GRBLunits)
		{
		if (GRBLunits == MM)
			{
			alert("Error", "GRBL configured to mm - CAD file sends Inches! - Change units in CAD/CAM software to mm");
			error("Fatal Error : units mismatch between CADfile and GRBL setting");
			}
		else
			{
			alert("Error", "GRBL configured to inches - CAD file sends mm! - Change units in CAD/CAM software to inches");
			error("Fatal Error : units mismatch between CADfile and GRBL setting");
			}
		}

	// 2. is RadiusCompensation not set incorrectly ?
	onRadiusCompensation();

	// 3. here you set all the properties of your machine, so they can be used later on
	var myMachine = getMachineConfiguration();
	myMachine.setWidth(600);
	myMachine.setDepth(800);
	myMachine.setHeight(130);
	myMachine.setMaximumSpindlePower(700);
	myMachine.setMaximumSpindleSpeed(30000);
	myMachine.setMilling(true);
	myMachine.setTurning(false);
	myMachine.setToolChanger(false);
	myMachine.setNumberOfTools(1);
	myMachine.setNumberOfWorkOffsets(6);
	myMachine.setVendor("Franke");
	myMachine.setModel("CNC 2018");
	myMachine.setControl("EstlCAM 11");

	writeln("%");																								// Punch-Tape Begin, commented out as not supported by GRBL

	var productName = getProduct();
	writeComment("Made in : " + productName);
	writeComment("G-Code optimized for " + myMachine.getVendor() + " " + myMachine.getModel() + " with " + myMachine.getControl() + " controller");

	writeln("");

	if (programName)
		{
		writeComment("Program Name : " + programName);
		}
	if (programComment)
		{
		writeComment("Program Comments : " + programComment);
		}

	var numberOfSections = getNumberOfSections();
	writeComment(numberOfSections + " Operation" + ((numberOfSections == 1)?"":"s") + " :");

	
	}

function onComment(message)
	{
	writeComment(message);
	}

function forceXYZ()
	{
	xOutput.reset();
	yOutput.reset();
	zOutput.reset();
	}

function forceAny()
	{
	forceXYZ();
	feedOutput.reset();
	}

function onSection()
	{
	
	var nmbrOfSections = getNumberOfSections();		// how many operations are there in total
	var sectionId = getCurrentSectionId();			// what is the number of this operation (starts from 0)
	var section = getSection(sectionId);			// what is the section-object for this operation

	// Insert a small comment section to identify the related G-Code in a large multi-operations file
	var comment = "Operation " + (sectionId + 1) + " of " + nmbrOfSections;
	if (hasParameter("operation-comment"))
		{
		comment = comment + " : " + getParameter("operation-comment");
		}
	writeComment(comment);
	writeln("");

	
	
	var tool = section.getTool();
	
	if(!isFirstSection())
		{
			writeBlock(mFormat.format(6), "(" + tool.getDescription() + ")");
		}

	writeBlock(mFormat.format(3), sOutput.format(tool.spindleRPM));

	// If the machine has coolant, write M8 or M9
	if (properties.hasCoolant)
		{
		if (tool.coolant)
			{
			writeBlock(mFormat.format(8));
			}
		else
			{
			writeBlock(mFormat.format(9));
			}
		}

	forceXYZ();

	var remaining = currentSection.workPlane;
	if (!isSameDirection(remaining.forward, new Vector(0, 0, 1)))
		{
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

function onDwell(seconds)
	{
	}

function onSpindleSpeed(spindleSpeed)
	{
	writeBlock(sOutput.format(spindleSpeed));
	}

function onRadiusCompensation()
	{
	var radComp = getRadiusCompensation();
	var sectionId = getCurrentSectionId();
	if (radComp != RADIUS_COMPENSATION_OFF)
		{
		alert("Error", "RadiusCompensation is not supported in GRBL - Change RadiusCompensation in CAD/CAM software to Off/Center/Computer");
		error("Fatal Error in Operation " + (sectionId + 1) + ": RadiusCompensation is found in CAD file but is not supported in GRBL");
		return;
		}
	}

function onRapid(_x, _y, _z)
	{
	var x = xOutput.format(_x);
	var y = yOutput.format(_y);
	var z = zOutput.format(_z);
	
		writeBlock("G00", x, y, z);
		feedOutput.reset();
		
	}

function onLinear(_x, _y, _z, feed)
	{
	var x = xOutput.format(_x);
	var y = yOutput.format(_y);
	var z = zOutput.format(_z);
	var f = feedOutput.format(feed);

	if (x || y || z)
		{
		writeBlock("G01", x, y, z, f);
		}
	else if (f)
		{
		if (getNextRecord().isMotion())
			{
			feedOutput.reset(); // force feed on next line
			}
		else
			{
			writeBlock("G01", f);
			}
		}
	}

function onRapid5D(_x, _y, _z, _a, _b, _c)
	{
	alert("Error", "Tool-Rotation detected - GRBL only supports 3 Axis");
	error("Tool-Rotation detected but GRBL only supports 3 Axis");
	}

function onLinear5D(_x, _y, _z, _a, _b, _c, feed)
	{
	alert("Error", "Tool-Rotation detected - GRBL only supports 3 Axis");
	error("Tool-Rotation detected but GRBL only supports 3 Axis");
	}

function onCircular(clockwise, cx, cy, cz, x, y, z, feed)
	{
	
	var start = getCurrentPosition();
	if (isFullCircle())
		{
		if (isHelical())
			{
			linearize(tolerance);
			return;
			}

		switch (getCircularPlane())
			{
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
		}
	else
		{
		switch (getCircularPlane())
			{
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

function onSectionEnd()
	{
	}

function onClose()
	{
	writeBlock("G00", xOutput.format(0), yOutput.format(0));
		
	writeln("%");																									// EndOfFile marker
	}


