#include "BankedSonyFDC.hh"

#include "DriveMultiplexer.hh"
#include "WD2793.hh"

#include "CacheLine.hh"
#include "MSXException.hh"
#include "narrow.hh"
#include "ranges.hh"
#include "serialize.hh"

namespace openmsx {

BankedSonyFDC::BankedSonyFDC(DeviceConfig& config)
	: WD2793BasedFDC(config)
	, romBlockDebug(*this, std::span{&bank, 1}, 0x4000, 0x4000, 14)
	, memory(subspan<0x4000>(*rom))
	, blockMask(narrow_cast<byte>((rom->size() / 0x4000) - 1))
{
	auto size = rom->size();
	if (size == 0 || (size % 0x4000) != 0 || (size / 0x4000) > 256) {
		throw MSXException("BankedSonyFDC rom size must be N x 16kB (N <= 256)");
	}
	reset(getCurrentTime());
}

void BankedSonyFDC::reset(EmuTime time)
{
	WD2793BasedFDC::reset(time);
	setBank(0);
	writeMem(0x7FFC, 0x00, time);
	writeMem(0x7FFD, 0x00, time);
}

void BankedSonyFDC::setBank(byte value)
{
	invalidateDeviceRCache(0x4000, 0x4000);
	bank = value & blockMask;
	memory = subspan<0x4000>(*rom, 0x4000 * bank);
}

byte BankedSonyFDC::readMem(uint16_t address, EmuTime time)
{
	switch (address) {
	case 0x7FF8: return controller.getStatusReg(time);
	case 0x7FF9: return controller.getTrackReg(time);
	case 0x7FFA: return controller.getSectorReg(time);
	case 0x7FFB: return controller.getDataReg(time);
	case 0x7FFD: {
		byte res = driveReg & ~4;
		if (!multiplexer.diskChanged()) res |= 4;
		return res;
	}
	case 0x7FFF: {
		byte value = 0xFF;
		if (controller.getIRQ(time))  value &= ~0x40;
		if (controller.getDTRQ(time)) value &= ~0x80;
		return value;
	}
	default:
		return peekMem(address, time);
	}
}

byte BankedSonyFDC::peekMem(uint16_t address, EmuTime time) const
{
	if ((address < 0x4000) || (address >= 0x8000)) return 0xFF;
	if (address >= 0x7FF0) {
		switch (address) {
		case 0x7FF0: return bank;
		case 0x7FF8: return controller.peekStatusReg(time);
		case 0x7FF9: return controller.peekTrackReg(time);
		case 0x7FFA: return controller.peekSectorReg(time);
		case 0x7FFB: return controller.peekDataReg(time);
		case 0x7FFC: return sideReg;
		case 0x7FFD: {
			byte res = driveReg & ~4;
			if (!multiplexer.peekDiskChanged()) res |= 4;
			return res;
		}
		case 0x7FFF: {
			byte value = 0xFF;
			if (controller.peekIRQ(time))  value &= ~0x40;
			if (controller.peekDTRQ(time)) value &= ~0x80;
			return value;
		}
		default: return 0xFF;   // 7FF1-7FF7, 7FFE
		}
	}
	return memory[address & 0x3FFF];
}

const byte* BankedSonyFDC::getReadCacheLine(uint16_t start) const
{
	if ((start & 0x3FF0) == (0x3FF0 & CacheLine::HIGH)) return nullptr;
	if ((0x4000 <= start) && (start < 0x8000)) return &memory[start & 0x3FFF];
	return unmappedRead.data();
}

void BankedSonyFDC::writeMem(uint16_t address, byte value, EmuTime time)
{
	switch (address) {
	case 0x7FF0: setBank(value); break;
	case 0x7FF8: controller.setCommandReg(value, time); break;
	case 0x7FF9: controller.setTrackReg(value, time); break;
	case 0x7FFA: controller.setSectorReg(value, time); break;
	case 0x7FFB: controller.setDataReg(value, time); break;
	case 0x7FFC:
		sideReg = value;
		multiplexer.setSide(value & 1);
		break;
	case 0x7FFD: {
		driveReg = value;
		auto drive = [&] {
			switch (value & 3) {
			case 0: case 2: return DriveMultiplexer::Drive::A;
			case 1:         return DriveMultiplexer::Drive::B;
			default:        return DriveMultiplexer::Drive::NONE;
			}
		}();
		multiplexer.selectDrive(drive, time);
		multiplexer.setMotor((value & 128) != 0, time);
		break;
	}
	default: break;
	}
}

byte* BankedSonyFDC::getWriteCacheLine(uint16_t address)
{
	if ((address & 0x3FF0) == (0x3FF0 & CacheLine::HIGH)) return nullptr;
	return unmappedWrite.data();
}

template<typename Archive>
void BankedSonyFDC::serialize(Archive& ar, unsigned /*version*/)
{
	ar.template serializeBase<WD2793BasedFDC>(*this);
	ar.serialize("sideReg",  sideReg,
	             "driveReg", driveReg,
	             "bank",     bank);
	if constexpr (Archive::IS_LOADER) setBank(bank);
}
INSTANTIATE_SERIALIZE_METHODS(BankedSonyFDC);
REGISTER_MSXDEVICE(BankedSonyFDC, "BankedSonyFDC");

} // namespace openmsx
