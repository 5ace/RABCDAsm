/*
 *  Copyright (C) 2010 Vladimir Panteleev <vladimir@thecybershadow.net>
 *  This file is part of RABCDAsm.
 *
 *  RABCDAsm is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  RABCDAsm is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with RABCDAsm.  If not, see <http://www.gnu.org/licenses/>.
 */

module disassembler;

import std.file;
import std.string;
import std.conv;
import std.exception;
import abcfile;
import asprogram;

final class StringBuilder
{
	char[] buf;
	size_t pos;
	string filename;

	this(string filename)
	{
		this.filename = filename;
		buf.length = 1024;
	}

	void opCatAssign(string s)
	{
		checkIndent();
		auto end = pos + s.length;
		while (buf.length < end)
			buf.length = buf.length*2;
		buf[pos..end] = s;
		pos = end;
	}

	void opCatAssign(char c)
	{
		if (buf.length < pos+1) // speed hack: no loop, no indent check
			buf.length = buf.length*2;
		buf[pos++] = c;
	}

	void save()
	{
		string[] dirSegments = split(filename, "/");
		for (int l=0; l<dirSegments.length-1; l++)
		{
			auto subdir = join(dirSegments[0..l+1], "/");
			if (!exists(subdir))
				mkdir(subdir);
		}
		write(filename, buf[0..pos]);
	}

	int indent;
	bool indented;

	void newLine()
	{
		this ~= '\n';
		indented = false;
	}

	void noIndent()
	{
		indented = true;
	}

	void checkIndent()
	{
		if (!indented)
		{
			for (int i=0; i<indent; i++)
				this ~= ' ';
			indented = true;
		}
	}
}

final class RefBuilder : ASTraitsVisitor
{
	string[void*] objName;
	ASProgram.Class[string] classByName;
	ASProgram.Method[string] methodByName;

	string[uint] privateNamespaceNames;
	uint[string] privateNamespaceByName;

	ASProgram.Multiname[] context;

	this(ASProgram as)
	{
		super(as);
	}

	override void run()
	{
		foreach (i, ref v; as.scripts)
			addMethod(v.sinit, "script" ~ to!string(i) ~ "_sinit");
		foreach (vclass; as.orphanClasses)
			addClass(vclass, "orphan");
		foreach (method; as.orphanMethods)
			addMethod(method, "orphan");
		super.run();
	}

	override void visitTrait(ref ASProgram.Trait trait)
	{
		auto m = trait.name;

		if (m.kind != ASType.QName)
			throw new Exception("Trait name is not a QName");
		
		visitMultiname(m);
		
		context ~= m;
		switch (trait.kind)
		{
			case TraitKind.Class:
				addClass(trait.vClass.vclass);
				break;
			case TraitKind.Function:
				addMethod(trait.vFunction.vfunction);
				break;
			case TraitKind.Method:
				addMethod(trait.vMethod.vmethod);
				break;
			case TraitKind.Getter:
				addMethod(trait.vMethod.vmethod, "getter");
				break;
			case TraitKind.Setter:
				addMethod(trait.vMethod.vmethod, "setter");
				break;
			default:
				break;
		}
		super.visitTrait(trait);
		context = context[0..$-1];
	}

	string addPrivateNamespace(uint index, string bname)
	{
		string name = bname;
		{
			int n = 0;
			uint* pindex;
			while ((pindex = name in privateNamespaceByName) !is null && *pindex != index)
				name = bname ~ to!string(++n);
		}
		auto pname = index in privateNamespaceNames;
		if (pname)
		{
			if (*pname != name)
				throw new Exception("Ambiguous private namespace: " ~ *pname ~ " and " ~ name);
		}
		else
		{
			privateNamespaceNames[index] = name;
			privateNamespaceByName[name] = index;
		}
		return name;
	}

	void visitNamespace(ASProgram.Namespace ns)
	{
		if (ns.kind == ASType.PrivateNamespace && context.length>0 && context[0].vQName.ns.kind != ASType.PrivateNamespace)
			addPrivateNamespace(ns.privateIndex, qNameToString(context[0]));
	}

	void visitNamespaceSet(ASProgram.Namespace[] nsSet)
	{
		foreach (ns; nsSet)
			visitNamespace(ns);
	}

	void visitMultiname(ASProgram.Multiname m)
	{
		with (m)
			switch (kind)
			{
				case ASType.QName:
				case ASType.QNameA:
					visitNamespace(vQName.ns);
					break;
				case ASType.Multiname:
				case ASType.MultinameA:
					visitNamespaceSet(vMultiname.nsSet);
					break;
				case ASType.MultinameL:
				case ASType.MultinameLA:
					visitNamespaceSet(vMultinameL.nsSet);
					break;
				case ASType.TypeName:
					visitMultiname(vTypeName.name);
					foreach (param; vTypeName.params)
						visitMultiname(param);
					break;
				default:
					break;
			}
	}

	void visitMethodBody(ASProgram.MethodBody b)
	{
		foreach (ref instruction; b.instructions)
			foreach (i, type; opcodeInfo[instruction.opcode].argumentTypes)
				switch (type)
				{
					case OpcodeArgumentType.Namespace:
						visitNamespace(instruction.arguments[i].namespacev);
						break;
					case OpcodeArgumentType.Multiname:
						visitMultiname(instruction.arguments[i].multinamev);
						break;
					default:
						break;
				}
	}

	static string qNameToString(ASProgram.Multiname m)
	{
		assert(m.kind == ASType.QName);
		return (m.vQName.ns.name.length ? m.vQName.ns.name ~ ":" : "") ~ m.vQName.name;
	}

	string contextToString(string field)
	{
		string[] strings = new string[context.length + (field ? 1 : 0)];
		foreach (i, m; context)
			strings[i] = qNameToString(m);
		if (field)
			strings[$-1] = field;
		char[] s = join(strings, "/").dup;
		foreach (ref c; s)
			if (c < 0x20 || c == '"')
				c = '_';
		return assumeUnique(s);
	}

	string addObject(T)(T obj, ref T[string] objByName, string field)
	{
		auto name = contextToString(field);
		auto uniqueName = name;
		int i = 1;
		while (uniqueName in objByName)
			uniqueName = name ~ "_" ~ to!string(++i);
		objByName[uniqueName] = obj;
		objName[cast(void*)obj] = uniqueName;
		return uniqueName;
	}

	void addClass(ASProgram.Class vclass, string field = null)
	{
		addObject(vclass, classByName, field);
		addMethod(vclass.cinit, "cinit");
		addMethod(vclass.instance.iinit, "iinit");
	}

	void addMethod(ASProgram.Method method, string field = null)
	{
		addObject(method, methodByName, field);
		if (method.vbody)
			visitMethodBody(method.vbody);
	}

	string getObjectName(T)(T obj, ref T[string] objByName)
	{
		auto pname = cast(void*)obj in objName;
		if (pname)
			return *pname;
		else
			return addObject(obj, objByName, "orphan");
	}

	string getClassName(ASProgram.Class vclass)
	{
		return getObjectName(vclass, classByName);
	}

	string getMethodName(ASProgram.Method method)
	{
		return getObjectName(method, methodByName);
	}

	string getPrivateNamespaceName(uint index)
	{
		auto pname = index in privateNamespaceNames;
		if (pname)
			return *pname;
		else
			//throw new Exception("Nameless private namespace: " ~ to!string(index));
			return addPrivateNamespace(index, "OrphanPrivateNamespace");
	}
}

final class Disassembler
{
	ASProgram as;
	string name, dir;
	RefBuilder refs;

	version (Windows)
		string[string] filenameMappings;

	this(ASProgram as, string dir, string name)
	{
		this.as = as;
		this.name = name;
		this.dir = dir;
	}

	void disassemble()
	{
		refs = new RefBuilder(as);
		refs.run();

		StringBuilder sb = new StringBuilder(dir ~ "/" ~ name ~ ".main.asasm");

		sb ~= "#include ";
		dumpString(sb, name ~ ".privatens.asasm");
		sb.newLine();

		sb ~= "program";
		sb.indent++; sb.newLine();

		sb ~= "minorversion ";
		sb ~= to!string(as.minorVersion);
		sb.newLine();
		sb ~= "majorversion ";
		sb ~= to!string(as.majorVersion);
		sb.newLine();
		sb.newLine();

		foreach (i, script; as.scripts)
		{
			dumpScript(sb, script, i);
			sb.newLine();
		}

		if (as.orphanClasses.length)
		{
			sb.newLine();
			sb ~= "; ===========================================================================";
			sb.newLine();
			sb.newLine();

			foreach (i, vclass; as.orphanClasses)
			{
				sb ~= "class";
				dumpClass(sb, vclass);
				sb.newLine();
			}
		}

		if (as.orphanMethods.length)
		{
			sb.newLine();
			sb ~= "; ===========================================================================";
			sb.newLine();
			sb.newLine();

			foreach (i, method; as.orphanMethods)
			{
				sb ~= "method";
				dumpMethod(sb, method);
				sb.newLine();
			}
		}

		sb.indent--;
		sb ~= "end ; program"; sb.newLine();

		sb.save();

		// now dump the private namespace indices
		sb = new StringBuilder(dir ~ "/" ~ name ~ ".privatens.asasm");
		uint[] indices = refs.privateNamespaceNames.keys.sort;
		foreach (index; indices)
		{
			sb ~= "#privatens " ~ to!string(index) ~ " ";
			dumpString(sb, refs.privateNamespaceNames[index]);
			sb.newLine();
		}
		sb.save();
	}

	void dumpInt(StringBuilder sb, long v)
	{
		if (v == ABCFile.NULL_INT)
			sb ~= "null";
		else
			sb ~= to!string(v);
	}

	void dumpUInt(StringBuilder sb, ulong v)
	{
		if (v == ABCFile.NULL_UINT)
			sb ~= "null";
		else
			sb ~= to!string(v);
	}

	void dumpDouble(StringBuilder sb, double v)
	{
		if (v == ABCFile.NULL_DOUBLE)
			sb ~= "null";
		else
			sb ~= format("%.18g", v);
	}

	void dumpString(StringBuilder sb, string str)
	{
		if (str is null)
			sb ~= "null";
		else
		{
			static const char[16] hexDigits = "0123456789ABCDEF";

			sb ~= '"';
			foreach (c; str)
				if (c == 0x0A)
					sb ~= `\n`;
				else
				if (c == 0x0D)
					sb ~= `\r`;
				else
				if (c == '\\')
					sb ~= `\\`;
				else
				if (c == '"')
					sb ~= `\"`;
				else
				if (c < 0x20)
				{
					sb ~= `\x`;
					sb ~= hexDigits[c / 0x10];
					sb ~= hexDigits[c % 0x10];
				}
				else
					sb ~= c;
			sb ~= '"';
		}
	}

	void dumpNamespace(StringBuilder sb, ASProgram.Namespace namespace)
	{
		if (namespace is null)
			sb ~= "null";
		else
		with (namespace)
		{
			sb ~= ASTypeNames[kind];
			sb ~= '(';
			dumpString(sb, name);
			if (kind == ASType.PrivateNamespace)
			{
				sb ~= ", ";
				dumpString(sb, refs.getPrivateNamespaceName(privateIndex));
			}
			sb ~= ')';
		}
	}

	void dumpNamespaceSet(StringBuilder sb, ASProgram.Namespace[] set)
	{
		if (set is null)
			sb ~= "null";
		else
		{
			sb ~= '[';
			foreach (i, ns; set)
			{
				dumpNamespace(sb, ns);
				if (i < set.length-1)
					sb ~= ", ";
			}
			sb ~= ']';
		}
	}

	void dumpMultiname(StringBuilder sb, ASProgram.Multiname multiname)
	{
		if (multiname is null)
			sb ~= "null";
		else
		with (multiname)
		{
			sb ~= ASTypeNames[kind];
			sb ~= '(';
			switch (kind)
			{
				case ASType.QName:
				case ASType.QNameA:
					dumpNamespace(sb, vQName.ns);
					sb ~= ", ";
					dumpString(sb, vQName.name);
					break;
				case ASType.RTQName:
				case ASType.RTQNameA:
					dumpString(sb, vRTQName.name);
					break;
				case ASType.RTQNameL:
				case ASType.RTQNameLA:
					break;
				case ASType.Multiname:
				case ASType.MultinameA:
					dumpString(sb, vMultiname.name);
					sb ~= ", ";
					dumpNamespaceSet(sb, vMultiname.nsSet);
					break;
				case ASType.MultinameL:
				case ASType.MultinameLA:
					dumpNamespaceSet(sb, vMultinameL.nsSet);
					break;
				case ASType.TypeName:
					dumpMultiname(sb, vTypeName.name);
					sb ~= '<';
					foreach (i, param; vTypeName.params)
					{
						dumpMultiname(sb, param);
						if (i < vTypeName.params.length-1)
							sb ~= ", ";
					}
					sb ~= '>';
					break;
				default:
					throw new .Exception("Unknown Multiname kind");
			}
			sb ~= ')';
		}
	}

	void dumpTraits(StringBuilder sb, ASProgram.Trait[] traits)
	{
		foreach (ref trait; traits)
		{
			sb ~= "trait ";
			sb ~= TraitKindNames[trait.kind];
			sb ~= ' ';
			dumpMultiname(sb, trait.name);
			if (trait.attr)
				dumpFlags!(true)(sb, trait.attr, TraitAttributeNames);
			bool inLine = false;
			switch (trait.kind)
			{
				case TraitKind.Slot:
				case TraitKind.Const:
					if (trait.vSlot.slotId)
					{
						sb ~= " slotid ";
						dumpUInt(sb, trait.vSlot.slotId);
					}
					if (trait.vSlot.typeName)
					{
						sb ~= " type ";
						dumpMultiname(sb, trait.vSlot.typeName);
					}
					if (trait.vSlot.value.vkind)
					{
						sb ~= " value ";
						dumpValue(sb, trait.vSlot.value);
					}
					inLine = true;
					break;
				case TraitKind.Class:
					if (trait.vClass.slotId)
					{
						sb ~= " slotid ";
						dumpUInt(sb, trait.vClass.slotId);
					}
					sb.indent++; sb.newLine();
					sb ~= "class";
					dumpClass(sb, trait.vClass.vclass);
					break;
				case TraitKind.Function:
					if (trait.vFunction.slotId)
					{
						sb ~= " slotid ";
						dumpUInt(sb, trait.vFunction.slotId);
					}
					sb.indent++; sb.newLine();
					sb ~= "method";
					dumpMethod(sb, trait.vFunction.vfunction);
					break;
				case TraitKind.Method:
				case TraitKind.Getter:
				case TraitKind.Setter:
					if (trait.vMethod.dispId)
					{
						sb ~= " dispid ";
						dumpUInt(sb, trait.vMethod.dispId);
					}
					sb.indent++; sb.newLine();
					sb ~= "method";
					dumpMethod(sb, trait.vMethod.vmethod);
					break;
				default:
					throw new Exception("Unknown trait kind");
			}

			foreach (metadata; trait.metadata)
			{
				if (inLine)
				{
					sb.indent++; sb.newLine();
					inLine = false;
				}
				dumpMetadata(sb, metadata);
			}

			if (inLine)
				{ sb ~= " end"; sb.newLine(); }
			else
				{ sb.indent--; sb ~= "end ; trait"; sb.newLine(); }
		}
	}

	void dumpMetadata(StringBuilder sb, ASProgram.Metadata metadata)
	{
		sb ~= "metadata ";
		dumpString(sb, metadata.name);
		sb.indent++; sb.newLine();
		foreach (ref item; metadata.items)
		{
			sb ~= "item ";
			dumpString(sb, item.key);
			sb ~= " ";
			dumpString(sb, item.value);
			sb.newLine();
		}
		sb.indent--; sb ~= "end ; metadata"; sb.newLine();
	}

	void dumpFlags(bool oneLine = false)(StringBuilder sb, ubyte flags, const string[] names)
	{
		for (int i=0; flags; i++, flags>>=1)
			if (flags & 1)
			{
				static if (oneLine)
					sb ~= " flag ";
				else
					sb ~= "flag ";
				sb ~= names[i];
				static if (!oneLine)
					sb.newLine();
			}
	}

	void dumpValue(StringBuilder sb, ref ASProgram.Value value)
	{
		with (value)
		{
			sb ~= ASTypeNames[vkind];
			sb ~= '(';
			switch (vkind)
			{
				case ASType.Integer:
					dumpInt(sb, vint);
					break;
				case ASType.UInteger:
					dumpUInt(sb, vuint);
					break;
				case ASType.Double:
					dumpDouble(sb, vdouble);
					break;
				case ASType.Utf8:
					dumpString(sb, vstring);
					break;
				case ASType.Namespace:
				case ASType.PackageNamespace:
				case ASType.PackageInternalNs:
				case ASType.ProtectedNamespace:
				case ASType.ExplicitNamespace:
				case ASType.StaticProtectedNs:
				case ASType.PrivateNamespace:
					dumpNamespace(sb, vnamespace);
					break;
				case ASType.True:
				case ASType.False:
				case ASType.Null:
				case ASType.Undefined:
					break;
				default:
					throw new Exception("Unknown type");
			}

			sb ~= ')';
		}
	}

	void dumpMethod(StringBuilder sb, ASProgram.Method method)
	{
		sb.indent++; sb.newLine();
		if (method.name !is null)
		{
			sb ~= "name ";
			dumpString(sb, method.name);
			sb.newLine();
		}
		auto refName = cast(void*)method in refs.objName;
		if (refName)
		{
			sb ~= "refid ";
			dumpString(sb, *refName);
			sb.newLine();
		}
		foreach (m; method.paramTypes)
		{
			sb ~= "param ";
			dumpMultiname(sb, m);
			sb.newLine();
		}
		if (method.returnType)
		{
			sb ~= "returns ";
			dumpMultiname(sb, method.returnType);
			sb.newLine();
		}
		dumpFlags(sb, method.flags, MethodFlagNames);
		foreach (ref v; method.options)
		{
			sb ~= "optional ";
			dumpValue(sb, v);
			sb.newLine();
		}
		foreach (s; method.paramNames)
		{
			sb ~= "paramname ";
			dumpString(sb, s);
			sb.newLine();
		}
		if (method.vbody)
			dumpMethodBody(sb, method.vbody);
		sb.indent--; sb ~= "end ; method"; sb.newLine();
	}

	string toFileName(string refid)
	{
		char[] buf = refid.dup;
		foreach (ref c; buf)
			if (c == '.' || c == ':')
				c = '/';
			else
			if (c == '\\' || c == '*' || c == '?' || c == '"' || c == '<' || c == '>' || c == '|')
				c = '_';
		string filename = assumeUnique(buf);

		version (Windows)
		{
			string[] dirSegments = split(filename, "/");
			for (int l=0; l<dirSegments.length; l++)
			{
			again:	
				string subpath = join(dirSegments[0..l+1], "/");
				string subpathl = tolower(subpath);
				string* canonicalp = subpathl in filenameMappings;
				if (canonicalp && *canonicalp != subpath)
				{
					dirSegments[l] = dirSegments[l] ~ "_"; // not ~=
					goto again;
				}
				filenameMappings[subpathl] = subpath;
			}
			filename = join(dirSegments, "/");
		}

		return filename ~ ".asasm";
	}

	void dumpClass(StringBuilder mainsb, ASProgram.Class vclass)
	{
		if (mainsb.filename.split("/").length != 2)
			throw new Exception("TODO: nested classes");
		auto refName = cast(void*)vclass in refs.objName;
		auto filename = toFileName(refs.getClassName(vclass));
		StringBuilder sb = new StringBuilder(dir ~ "/" ~ filename);
		if (refName)
		{
			sb ~= "refid ";
			dumpString(sb, *refName);
			sb.newLine();
		}
		sb ~= "instance ";
		dumpInstance(sb, vclass.instance);
		sb ~= "cinit"; dumpMethod(sb, vclass.cinit);
		dumpTraits(sb, vclass.traits);

		sb.save();

		mainsb.indent++; mainsb.newLine();
		mainsb ~= "#include ";
		dumpString(mainsb, filename);
		mainsb.newLine();
		mainsb.indent--; mainsb ~= "end ; class"; mainsb.newLine();
	}

	void dumpInstance(StringBuilder sb, ASProgram.Instance instance)
	{
		dumpMultiname(sb, instance.name);
		sb.indent++; sb.newLine();
		if (instance.superName)
		{
			sb ~= "extends ";
			dumpMultiname(sb, instance.superName);
			sb.newLine();
		}
		foreach (i; instance.interfaces)
		{
			sb ~= "implements ";
			dumpMultiname(sb, i);
			sb.newLine();
		}
		dumpFlags(sb, instance.flags, InstanceFlagNames);
		if (instance.protectedNs)
		{
			sb ~= "protectedns ";
			dumpNamespace(sb, instance.protectedNs);
			sb.newLine();
		}
		sb ~= "iinit"; dumpMethod(sb, instance.iinit);
		dumpTraits(sb, instance.traits);
		sb.indent--; sb ~= "end ; instance"; sb.newLine();
	}

	void dumpScript(StringBuilder sb, ASProgram.Script script, uint index)
	{
		sb ~= "script ; ";
		sb ~= to!string(index);
		sb.indent++; sb.newLine();
		sb ~= "sinit"; dumpMethod(sb, script.sinit);
		dumpTraits(sb, script.traits);
		sb.indent--; sb ~= "end ; script"; sb.newLine();
	}

	void dumpUIntField(StringBuilder sb, string name, uint value)
	{
		sb ~= name;
		sb ~= ' ';
		dumpUInt(sb, value);
		sb.newLine();
	}

	void dumpLabel(StringBuilder sb, ref ABCFile.Label label)
	{
		sb ~= 'L';
		sb ~= to!string(label.index);
		if (label.offset != 0)
		{
			if (label.offset > 0)
				sb ~= '+';
			sb ~= to!string(label.offset);
		}
	}
		
	void dumpMethodBody(StringBuilder sb, ASProgram.MethodBody mbody)
	{
		sb ~= "body";
		sb.indent++; sb.newLine();
		dumpUIntField(sb, "maxstack", mbody.maxStack);
		dumpUIntField(sb, "localcount", mbody.localCount);
		dumpUIntField(sb, "initscopedepth", mbody.initScopeDepth);
		dumpUIntField(sb, "maxscopedepth", mbody.maxScopeDepth);
		sb ~= "code";
		sb.newLine();

		bool[] labels = new bool[mbody.instructions.length+1];
		// reserve exception labels
		foreach (ref e; mbody.exceptions)
			labels[e.from.index] = labels[e.to.index] = labels[e.target.index] = true;
		dumpInstructions(sb, mbody.instructions, labels);

		sb ~= "end ; code";
		sb.newLine();
		foreach (ref e; mbody.exceptions)
		{
			sb ~= "try from ";
			dumpLabel(sb, e.from);
			sb ~= " to ";
			dumpLabel(sb, e.to);
			sb ~= " target ";
			dumpLabel(sb, e.target);
			sb ~= " type ";
			dumpMultiname(sb, e.excType);
			sb ~= " name ";
			dumpMultiname(sb, e.varName);
			sb ~= " end";
			sb.newLine();
		}
		dumpTraits(sb, mbody.traits);
		sb.indent--; sb ~= "end ; body"; sb.newLine();
	}

	void dumpInstructions(StringBuilder sb, ASProgram.Instruction[] instructions, bool[] labels)
	{
		sb.indent++;
		foreach (ref instruction; instructions)
			foreach (i, type; opcodeInfo[instruction.opcode].argumentTypes)
				switch (type)
				{
					case OpcodeArgumentType.JumpTarget:
					case OpcodeArgumentType.SwitchDefaultTarget:
						labels[instruction.arguments[i].jumpTarget.index] = true;
						break;
					case OpcodeArgumentType.SwitchTargets:
						foreach (ref label; instruction.arguments[i].switchTargets)
							labels[label.index] = true;
						break;
					default:
						break;
				}
		
		void checkLabel(uint ii)
		{
			if (labels[ii])
			{
				sb.noIndent();
				sb ~= 'L';
				sb ~= to!string(ii);
				sb ~= ':';
				sb.newLine();
			}
		}

		bool extraNewLine = false;
		foreach (ii, ref instruction; instructions)
		{
			if (extraNewLine)
				sb.newLine();
			extraNewLine = newLineAfter[instruction.opcode];
			checkLabel(ii);

			sb ~= opcodeInfo[instruction.opcode].name;
			auto argTypes = opcodeInfo[instruction.opcode].argumentTypes;
			if (argTypes.length)
			{
				for (int i=opcodeInfo[instruction.opcode].name.length; i<20; i++)
					sb ~= ' ';
				foreach (i, type; argTypes)
				{
					final switch (type)
					{
						case OpcodeArgumentType.Unknown:
							throw new Exception("Don't know how to disassemble OP_" ~ opcodeInfo[instruction.opcode].name);

						case OpcodeArgumentType.UByteLiteral:
							sb ~= to!string(instruction.arguments[i].ubytev);
							break;
						case OpcodeArgumentType.IntLiteral:
							sb ~= to!string(instruction.arguments[i].intv);
							break;
						case OpcodeArgumentType.UIntLiteral:
							sb ~= to!string(instruction.arguments[i].uintv);
							break;

						case OpcodeArgumentType.Int:
							dumpInt(sb, instruction.arguments[i].intv);
							break;
						case OpcodeArgumentType.UInt:
							dumpUInt(sb, instruction.arguments[i].uintv);
							break;
						case OpcodeArgumentType.Double:
							dumpDouble(sb, instruction.arguments[i].doublev);
							break;
						case OpcodeArgumentType.String:
							dumpString(sb, instruction.arguments[i].stringv);
							break;
						case OpcodeArgumentType.Namespace:
							dumpNamespace(sb, instruction.arguments[i].namespacev);
							break;
						case OpcodeArgumentType.Multiname:
							dumpMultiname(sb, instruction.arguments[i].multinamev);
							break;
						case OpcodeArgumentType.Class:
							dumpString(sb, refs.getClassName(instruction.arguments[i].classv));
							break;
						case OpcodeArgumentType.Method:
							dumpString(sb, refs.getMethodName(instruction.arguments[i].methodv));
							break;

						case OpcodeArgumentType.JumpTarget:
						case OpcodeArgumentType.SwitchDefaultTarget:
							dumpLabel(sb, instruction.arguments[i].jumpTarget);
							break;

						case OpcodeArgumentType.SwitchTargets:
							sb ~= '[';
							auto targets = instruction.arguments[i].switchTargets;
							foreach (ti, t; targets)
							{
								dumpLabel(sb, t);
								if (ti < targets.length-1)
									sb ~= ", ";
							}
							sb ~= ']';
							break;
					}
					if (i < argTypes.length-1)
						sb ~= ", ";
				}
			}
			sb.newLine();
		}
		checkLabel(instructions.length);
		sb.indent--;
	}
}

bool[256] newLineAfter;

static this()
{
	foreach (o; [
		Opcode.OP_callpropvoid,
		Opcode.OP_constructsuper,
		Opcode.OP_initproperty,
		Opcode.OP_ifeq,
		Opcode.OP_iffalse,
		Opcode.OP_ifge,
		Opcode.OP_ifgt,
		Opcode.OP_ifle,
		Opcode.OP_iflt,
		Opcode.OP_ifne,
		Opcode.OP_ifnge,
		Opcode.OP_ifngt,
		Opcode.OP_ifnle,
		Opcode.OP_ifnlt,
		Opcode.OP_ifstricteq,
		Opcode.OP_ifstrictne,
		Opcode.OP_iftrue,
		Opcode.OP_jump,
		Opcode.OP_lookupswitch,
		Opcode.OP_pushscope,
		Opcode.OP_returnvalue,
		Opcode.OP_returnvoid,
		Opcode.OP_setglobalslot,
		Opcode.OP_setlocal,
		Opcode.OP_setlocal0,
		Opcode.OP_setlocal1,
		Opcode.OP_setlocal2,
		Opcode.OP_setlocal3,
		Opcode.OP_setproperty,
		Opcode.OP_setpropertylate,
		Opcode.OP_setslot,
		Opcode.OP_setsuper
	])
		newLineAfter[o] = true;
}
