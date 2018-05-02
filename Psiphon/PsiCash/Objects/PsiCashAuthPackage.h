/*
 * Copyright (c) 2018, Psiphon Inc.
 * All rights reserved.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#import <Foundation/Foundation.h>

@interface PsiCashAuthPackage : NSObject
@property (nonatomic, assign, readonly) BOOL hasEarnerToken;
@property (nonatomic, assign, readonly) BOOL hasIndicatorToken;
@property (nonatomic, assign, readonly) BOOL hasSpenderToken;
- (id)initWithValidTokens:(NSArray<NSString*>*)validTokenTypes;
@end