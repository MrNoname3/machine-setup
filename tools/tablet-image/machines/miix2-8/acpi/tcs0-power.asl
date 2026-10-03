/*
 * The touchscreen also runs from the cameras' V18X and X285 rails, which the
 * firmware lists only for the cameras; listing them here keeps them up.
 */
DefinitionBlock ("", "SSDT", 2, "MIIX28", "TCS0PWR", 0x00000001)
{
    External (_SB_.I2C6.TCS0, DeviceObj)
    External (_SB_.P18X, PowerResObj)
    External (_SB_.P28X, PowerResObj)

    Scope (\_SB.I2C6.TCS0)
    {
        Name (_PR0, Package (0x02)
        {
            \_SB.P18X,
            \_SB.P28X
        })
    }
}
