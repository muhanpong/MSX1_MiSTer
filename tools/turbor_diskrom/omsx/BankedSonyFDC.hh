#ifndef BANKEDSONYFDC_HH
#define BANKEDSONYFDC_HH

// Test device (not upstream): WD2793 in the Sony/Philips memory map
// (registers at 0x7FF8-0x7FFF) combined with a turboR-style 16kB bank
// register at 0x7FF0, for a disk ROM image that is N x 16kB.
// Used to validate a turboR DOS2 kernel with a WD2793 driver.

#include "RomBlockDebuggable.hh"
#include "WD2793BasedFDC.hh"

#include <cstdint>
#include <span>

namespace openmsx {

class BankedSonyFDC final : public WD2793BasedFDC
{
public:
	explicit BankedSonyFDC(DeviceConfig& config);

	void reset(EmuTime time) override;
	[[nodiscard]] byte readMem(uint16_t address, EmuTime time) override;
	[[nodiscard]] byte peekMem(uint16_t address, EmuTime time) const override;
	void writeMem(uint16_t address, byte value, EmuTime time) override;
	[[nodiscard]] const byte* getReadCacheLine(uint16_t start) const override;
	[[nodiscard]] byte* getWriteCacheLine(uint16_t address) override;

	template<typename Archive>
	void serialize(Archive& ar, unsigned version);

private:
	void setBank(byte value);

	RomBlockDebuggable romBlockDebug;
	std::span<const byte, 0x4000> memory;
	const byte blockMask;
	byte bank = 0;
	byte sideReg = 0;
	byte driveReg = 0;
};

} // namespace openmsx

#endif
