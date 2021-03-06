package org.apache.lucene.analysis.standard;

/**
 * Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements.  See the NOTICE file distributed with
 * this work for additional information regarding copyright ownership.
 * The ASF licenses this file to You under the Apache License, Version 2.0
 * (the "License"); you may not use this file except in compliance with
 * the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import java.io.IOException;
import java.io.Reader;

import org.apache.lucene.analysis.Tokenizer;
import org.apache.lucene.analysis.tokenattributes.OffsetAttribute;
import org.apache.lucene.analysis.tokenattributes.PositionIncrementAttribute;
import org.apache.lucene.analysis.tokenattributes.CharTermAttribute;
import org.apache.lucene.analysis.tokenattributes.TypeAttribute;
import org.apache.lucene.util.AttributeSource;


/**
 * This class implements Word Break rules from the Unicode Text Segmentation 
 * algorithm, as specified in 
 * <a href="http://unicode.org/reports/tr29/">Unicode Standard Annex #29</a> 
 * <p/>
 * Tokens produced are of the following types:
 * <ul>
 *   <li>&lt;ALPHANUM&gt;: A sequence of alphabetic and numeric characters</li>
 *   <li>&lt;NUM&gt;: A number</li>
 *   <li>&lt;SOUTHEAST_ASIAN&gt;: A sequence of characters from South and Southeast
 *       Asian languages, including Thai, Lao, Myanmar, and Khmer</li>
 *   <li>&lt;IDEOGRAPHIC&gt;: A single CJKV ideographic character</li>
 *   <li>&lt;HIRAGANA&gt;: A single hiragana character</li>
 * </ul>
 * <b>WARNING</b>: Because JFlex does not support Unicode supplementary 
 * characters (characters above the Basic Multilingual Plane, which contains
 * those up to and including U+FFFF), this scanner will not recognize them
 * properly.  If you need to be able to process text containing supplementary 
 * characters, consider using the ICU4J-backed implementation in modules/analysis/icu  
 * (org.apache.lucene.analysis.icu.segmentation.ICUTokenizer)
 * instead of this class, since the ICU4J-backed implementation does not have
 * this limitation.
 */
%%

%unicode 6.0
%final
%public
%apiprivate
%class UAX29Tokenizer
%extends Tokenizer
%type boolean
%function getNextToken
%char

%init{
  super(in);
%init}

// WB4. X (Extend | Format)* --> X
//
ALetterEx      = \p{WB:ALetter}                     [\p{WB:Format}\p{WB:Extend}]*
// TODO: Convert hard-coded full-width numeric range to property intersection (something like [\p{Full-Width}&&\p{Numeric}]) once JFlex supports it
NumericEx      = [\p{WB:Numeric}\uFF10-\uFF19]      [\p{WB:Format}\p{WB:Extend}]*
KatakanaEx     = \p{WB:Katakana}                    [\p{WB:Format}\p{WB:Extend}]* 
MidLetterEx    = [\p{WB:MidLetter}\p{WB:MidNumLet}] [\p{WB:Format}\p{WB:Extend}]* 
MidNumericEx   = [\p{WB:MidNum}\p{WB:MidNumLet}]    [\p{WB:Format}\p{WB:Extend}]*
ExtendNumLetEx = \p{WB:ExtendNumLet}                [\p{WB:Format}\p{WB:Extend}]*

%{
  /** Alphanumeric sequences */
  public static final String WORD_TYPE = "<ALPHANUM>";
  
  /** Numbers */
  public static final String NUMERIC_TYPE = "<NUM>";
  
  /**
   * Chars in class \p{Line_Break = Complex_Context} are from South East Asian
   * scripts (Thai, Lao, Myanmar, Khmer, etc.).  Sequences of these are kept 
   * together as as a single token rather than broken up, because the logic
   * required to break them at word boundaries is too complex for UAX#29.
   * <p>
   * See Unicode Line Breaking Algorithm: http://www.unicode.org/reports/tr14/#SA
   */
  public static final String SOUTH_EAST_ASIAN_TYPE = "<SOUTHEAST_ASIAN>";
  
  public static final String IDEOGRAPHIC_TYPE = "<IDEOGRAPHIC>";
  
  public static final String HIRAGANA_TYPE = "<HIRAGANA>";
  
  private final CharTermAttribute termAtt = addAttribute(CharTermAttribute.class);
  private final OffsetAttribute offsetAtt = addAttribute(OffsetAttribute.class);
  private final PositionIncrementAttribute posIncrAtt 
    = addAttribute(PositionIncrementAttribute.class);
  private final TypeAttribute typeAtt = addAttribute(TypeAttribute.class);
  
  private int maxTokenLength = StandardAnalyzer.DEFAULT_MAX_TOKEN_LENGTH;
  private int posIncr;

  
  /**
   * @param source The AttributeSource to use
   * @param input The input reader
   */
  public UAX29Tokenizer(AttributeSource source, Reader input) {
    super(source, input);
    zzReader = input;
  }
  
  /**
   * @param factory The AttributeFactory to use
   * @param input The input reader
   */
  public UAX29Tokenizer(AttributeFactory factory, Reader input) {
    super(factory, input); 
    zzReader = input;
  }
  
  /** 
   * Set the max allowed token length.  Any token longer than this is skipped.
   * @param length the new max allowed token length
   */
  public void setMaxTokenLength(int length) {
    this.maxTokenLength = length;
  }

  /**
   * Returns the max allowed token length.  Any token longer than this is 
   * skipped.
   * @return the max allowed token length 
   */
  public int getMaxTokenLength() {
    return maxTokenLength;
  }

  @Override
  public final void end() {
    // set final offset
    int finalOffset = correctOffset(yychar + yylength());
    offsetAtt.setOffset(finalOffset, finalOffset);
  }

  @Override
  public void reset(Reader reader) throws IOException {
    super.reset(reader);
    yyreset(reader);
  }

  @Override
  public final boolean incrementToken() throws IOException {
    // This method is required because of two JFlex limitations:
    // 1. No way to insert code at the beginning of the generated scanning
    //    get-next-token method; and
    // 2. No way to declare @Override on the generated scanning method.
    clearAttributes();
    posIncr = 1;
    return getNextToken();
  }

  /**
   * Populates this TokenStream's CharTermAttribute and OffsetAttribute from
   * the current match, the TypeAttribute from the passed-in tokenType, and
   * the PositionIncrementAttribute to one, unless the immediately previous
   * token(s) was/were skipped because maxTokenLength was exceeded, in which
   * case the PositionIncrementAttribute is set to one plus the number of
   * skipped overly long tokens. 
   * <p/> 
   * If maxTokenLength is exceeded, the CharTermAttribute is set back to empty
   * and false is returned.
   * 
   * @param tokenType The type of the matching token
   * @return true there is a token available (not too long); false otherwise 
   */
  private boolean populateAttributes(String tokenType) {
    boolean isTokenAvailable = false;
    if (yylength() > maxTokenLength) {
      // When we skip a too-long token, we treat it like a stopword, introducing
      // a position increment gap
      ++posIncr;
    } else {
      termAtt.copyBuffer(zzBuffer, zzStartRead, yylength());
      posIncrAtt.setPositionIncrement(posIncr);
      offsetAtt.setOffset(correctOffset(yychar),
                          correctOffset(yychar + yylength()));
      typeAtt.setType(tokenType);
      isTokenAvailable = true;
    }
    return isTokenAvailable;
  }
%}

%%

// WB1. 	sot 	÷ 	
// WB2. 		÷ 	eot
//
<<EOF>> { return false; }


// WB8.   Numeric × Numeric
// WB11.  Numeric (MidNum | MidNumLet) × Numeric
// WB12.  Numeric × (MidNum | MidNumLet) Numeric
// WB13a. (ALetter | Numeric | Katakana | ExtendNumLet) × ExtendNumLet
// WB13b. ExtendNumLet × (ALetter | Numeric | Katakana)
//
{ExtendNumLetEx}* {NumericEx} ({ExtendNumLetEx}+ {NumericEx} 
                              | {MidNumericEx} {NumericEx} 
                              | {NumericEx})*
{ExtendNumLetEx}* 
  { if (populateAttributes(NUMERIC_TYPE)) return true; }


// WB5.   ALetter × ALetter
// WB6.   ALetter × (MidLetter | MidNumLet) ALetter
// WB7.   ALetter (MidLetter | MidNumLet) × ALetter
// WB9.   ALetter × Numeric
// WB10.  Numeric × ALetter
// WB13.  Katakana × Katakana
// WB13a. (ALetter | Numeric | Katakana | ExtendNumLet) × ExtendNumLet
// WB13b. ExtendNumLet × (ALetter | Numeric | Katakana)
//
{ExtendNumLetEx}*  ( {KatakanaEx} ({ExtendNumLetEx}* {KatakanaEx})* 
                   | ( {NumericEx}  ({ExtendNumLetEx}+ {NumericEx} | {MidNumericEx} {NumericEx} | {NumericEx})*
                     | {ALetterEx}  ({ExtendNumLetEx}+ {ALetterEx} | {MidLetterEx}  {ALetterEx} | {ALetterEx})* )+ ) 
({ExtendNumLetEx}+ ( {KatakanaEx} ({ExtendNumLetEx}* {KatakanaEx})* 
                   | ( {NumericEx}  ({ExtendNumLetEx}+ {NumericEx} | {MidNumericEx} {NumericEx} | {NumericEx})*
                     | {ALetterEx}  ({ExtendNumLetEx}+ {ALetterEx} | {MidLetterEx}  {ALetterEx} | {ALetterEx})* )+ ) )*
{ExtendNumLetEx}*  
  { if (populateAttributes(WORD_TYPE)) return true; }


// From UAX #29:
//
//    [C]haracters with the Line_Break property values of Contingent_Break (CB), 
//    Complex_Context (SA/South East Asian), and XX (Unknown) are assigned word 
//    boundary property values based on criteria outside of the scope of this
//    annex.  That means that satisfactory treatment of languages like Chinese
//    or Thai requires special handling.
// 
// In Unicode 6.0, only one character has the \p{Line_Break = Contingent_Break}
// property: U+FFFC ( ￼ ) OBJECT REPLACEMENT CHARACTER.
//
// In the ICU implementation of UAX#29, \p{Line_Break = Complex_Context}
// character sequences (from South East Asian scripts like Thai, Myanmar, Khmer,
// Lao, etc.) are kept together.  This grammar does the same below.
//
// See also the Unicode Line Breaking Algorithm:
//
//    http://www.unicode.org/reports/tr14/#SA
//
\p{LB:Complex_Context}+ { if (populateAttributes(SOUTH_EAST_ASIAN_TYPE)) return true; }

// WB14.  Any ÷ Any
//
\p{Script:Han} { if (populateAttributes(IDEOGRAPHIC_TYPE)) return true; }
\p{Script:Hiragana} { if (populateAttributes(HIRAGANA_TYPE)) return true; }


// WB3.   CR × LF
// WB3a.  (Newline | CR | LF) ÷
// WB3b.  ÷ (Newline | CR | LF)
// WB14.  Any ÷ Any
//
[^] { /* Not numeric, word, ideographic, hiragana, or SE Asian -- ignore it. */ }
